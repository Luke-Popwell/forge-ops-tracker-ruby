require "time"

module ForgeOpsTracker
  # Turns a raised exception into the JSON-able payload shape the ingestion
  # API expects. Backtrace parsing is a simple regex, not a full parser:
  # good enough for standard MRI backtrace lines across Ruby versions
  # (both the older `in \`method'` and newer `in 'method'` quoting styles).
  class EventBuilder
    LINE_PATTERN = /\A(?<file>.+?):(?<line>\d+)(?::in\s+(?<method>.+))?\z/
    MAX_FRAMES = 500

    # Identifies this gem to the server's auto language-detection on the project the event lands
    # in (see Project#note_sdk_platform server-side); "ruby", matching this repo's own sdks/
    # directory naming for every other language's client.
    SDK_NAME = "ruby".freeze

    # How many lines of source to grab on either side of the culprit line
    # (see #attach_source_context), and the longest a single captured line
    # is allowed to be before getting truncated; guards against a single
    # pathological minified/generated line ballooning the payload. ForgeOps
    # itself re-truncates on arrival too, the same "don't just trust the
    # SDK" posture MAX_FRAMES already gets on the server side.
    CONTEXT_LINES = 5
    MAX_CONTEXT_LINE_LENGTH = 500

    def initialize(configuration)
      @configuration = configuration
    end

    # transaction_name/endpoint/trace_id describe the request the error happened in (see
    # RequestState): transaction_name is the same "CheckoutsController#create" name the request's
    # root span and performance samples use, endpoint the human-readable route ("POST /checkout"),
    # trace_id the request's 32-character lowercase hex W3C trace id, which is also what links this
    # error to errors other services reported for the same trace. All three are nil outside a
    # request (a background job, a console session) and each key is left out of the payload
    # entirely when nil, the same "omit rather than send an empty value" treatment user and
    # breadcrumbs already get.
    #
    # With configuration.strict_privacy on, the finished payload goes through StrictPrivacy.event:
    # the message is replaced by its message_fingerprint (computed from the message as it would
    # otherwise have been sent, so after scrub_pii, which is also what the server fingerprints from
    # a gem without strict privacy, and keeps a message holding an email grouping together), and breadcrumbs, endpoint, the SQL statement, source context, the user's
    # email/username and every context/tag key not in privacy_allowed_fields are left out.
    def build(error, context: {}, user: nil, breadcrumbs: [], transaction_name: nil, endpoint: nil, trace_id: nil)
      payload = {
        exception_class: error.class.name,
        message: error.message.to_s,
        backtrace: backtrace_frames(error),
        occurred_at: Time.now.utc.iso8601,
        environment: configuration.environment.to_s,
        release: configuration.release,
        server_name: configuration.server_name,
        context: context || {},
        tags: {},
        sdk_name: SDK_NAME
      }
      payload[:user] = user if user && !user.empty?
      payload[:breadcrumbs] = breadcrumbs if breadcrumbs && !breadcrumbs.empty?
      payload[:transaction_name] = transaction_name if transaction_name
      payload[:endpoint] = endpoint if endpoint
      payload[:trace_id] = trace_id if trace_id
      attach_sql(payload, error)
      payload = scrub(payload)
      return payload unless configuration.strict_privacy

      StrictPrivacy.event(payload, allowed_fields: configuration.privacy_allowed_fields)
    end

    private
      attr_reader :configuration

      # exception_class/occurred_at/environment/release/server_name/sdk_name/user/transaction_name/
      # endpoint/trace_id are left alone; structured fields this gem or the host app sets
      # deliberately, not free text an exception or its context could accidentally spill sensitive
      # data into. endpoint in particular is a declared route pattern ("GET /orders/:id"), never
      # the literal request path, so it has no id or token in it to redact. user specifically is a
      # deliberate exemption, not an oversight: the server's own PiiScrubber-equivalent would
      # otherwise redact the exact email address this field exists to carry. breadcrumbs is *not*
      # exempt, unlike user: console-style/query/request trail entries are exactly the kind of free
      # text (a query's bind params showing up in a message, a URL with a token in it) the scrubber
      # exists to catch, matching the server's own api/v1/events_controller.rb treatment of this
      # field.
      def scrub(payload)
        return payload unless configuration.scrub_pii

        scrubbed = payload.merge(
          message: PiiScrubber.scrub(payload[:message]),
          backtrace: PiiScrubber.scrub(payload[:backtrace]),
          context: PiiScrubber.scrub(payload[:context]),
          tags: PiiScrubber.scrub(payload[:tags])
        )
        scrubbed[:sql_statement] = PiiScrubber.scrub(payload[:sql_statement]) if payload.key?(:sql_statement)
        scrubbed[:breadcrumbs] = PiiScrubber.scrub(payload[:breadcrumbs]) if payload.key?(:breadcrumbs)
        scrubbed
      end

      # See SqlStatement for what's read off the error and how it's masked. The statement itself
      # only goes out when capture_sql_statement is on; the extracted names go out on their own
      # (capture_sql_objects) so an issue can still name the procedure or view involved.
      def attach_sql(payload, error)
        return unless configuration.capture_sql_objects || configuration.capture_sql_statement

        masked = SqlStatement.mask(SqlStatement.find_in(error))
        return unless masked

        objects = SqlStatement.objects(masked)
        payload[:sql_objects] = objects if objects && configuration.capture_sql_objects
        payload[:sql_statement] = masked if configuration.capture_sql_statement && !configuration.strict_privacy
      end

      def backtrace_frames(error)
        Array(error.backtrace).first(MAX_FRAMES).filter_map { |line| parse_backtrace_line(line) }
      end

      def parse_backtrace_line(line)
        match = LINE_PATTERN.match(line.to_s)
        return nil unless match

        file = match[:file]
        frame = {
          file: file,
          line: match[:line].to_i,
          method: match[:method]&.gsub(/\A[`'"]|['"]\z/, ""),
          in_app: in_app?(file)
        }
        attach_source_context(frame)
      end

      def in_app?(file)
        root = configuration.app_root
        return false if root.nil? || root.to_s.empty?

        file.start_with?(root.to_s) && !file.include?("/gems/") && !file.include?("/bundle/")
      end

      # Reads a few lines of source straight off disk around the culprit
      # line, at raise-time, in the same running process the exception came
      # from. Gated on two things: the frame has to be in-app (never a
      # vendored dependency; there'd be nothing meaningful to show, and
      # it's not the host app's own code to begin with), and
      # configuration.capture_source_context has to be on (see
      # Configuration for why it defaults to true and why ForgeOps' own
      # per-project setting, not this flag, is the durable, protected way
      # to turn it off). Best-effort: any file that can't be read (deleted,
      # permission denied, a path that only ever existed inside a build
      # step and isn't present in this deployment) just means this one
      # frame gets no source context, not a raised error of its own. Never read at all under
      # strict privacy, which never sends it.
      def attach_source_context(frame)
        return frame unless configuration.capture_source_context && frame[:in_app] && !configuration.strict_privacy

        lines = File.readlines(frame[:file])
        index = frame[:line] - 1
        return frame unless index.between?(0, lines.length - 1)

        from = [ index - CONTEXT_LINES, 0 ].max
        to = [ index + CONTEXT_LINES, lines.length - 1 ].min

        frame.merge(
          context_line: truncate_line(lines[index]),
          pre_context: lines[from...index].map { |source_line| truncate_line(source_line) },
          post_context: lines[(index + 1)..to].map { |source_line| truncate_line(source_line) }
        )
      rescue SystemCallError, IOError
        frame
      end

      def truncate_line(line)
        line = line.chomp
        return line if line.length <= MAX_CONTEXT_LINE_LENGTH

        "#{line[0, MAX_CONTEXT_LINE_LENGTH]}..."
      end
  end
end
