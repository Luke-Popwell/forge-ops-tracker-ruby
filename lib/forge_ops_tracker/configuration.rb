require "uri"
require "socket"

module ForgeOpsTracker
  class Configuration
    # A single DSN string carries both the ingestion URL and
    # the project's api_key: "https://<api_key>@host/api/v1/events".
    attr_accessor :dsn, :environment, :release, :server_name, :app_root, :logger
    attr_accessor :enabled_environments, :queue_size, :open_timeout, :read_timeout, :scrub_pii
    attr_accessor :capture_source_context
    attr_accessor :capture_sql_objects, :capture_sql_statement
    attr_accessor :track_sessions, :session_flush_interval
    attr_accessor :track_performance, :performance_flush_interval
    attr_accessor :track_current_user
    attr_accessor :track_breadcrumbs, :max_breadcrumbs
    attr_accessor :track_failures, :failure_event_flush_interval
    attr_accessor :metric_flush_interval, :infrastructure_metric_flush_interval
    attr_accessor :gauge_poll_interval
    attr_accessor :track_tracing, :trace_capture_threshold_ms
    attr_accessor :explain_slow_queries, :explain_threshold_ms
    attr_accessor :propagate_traces, :trace_propagation_targets
    attr_accessor :detect_changes, :track_env_var_names
    attr_accessor :strict_privacy
    attr_reader :privacy_allowed_fields

    def initialize
      @dsn = ENV["FORGE_OPS_DSN"]
      @environment = self.class.resolve_environment
      @release = ENV["FORGE_OPS_RELEASE"]
      @server_name = safe_hostname
      @enabled_environments = %w[production staging]
      @queue_size = 1000
      @open_timeout = 2
      @read_timeout = 2
      @logger = nil
      # See PiiScrubber; redacts likely-sensitive content (emails,
      # credit cards, known API key formats, anything under a
      # suspiciously-named key) before a payload ever leaves this
      # process. ForgeOps itself scrubs again on arrival regardless, so
      # this is a second, earlier layer, not the only one; but "on" is
      # the only sane default.
      @scrub_pii = true
      # Whether EventBuilder reads a few lines of source off disk around
      # each in-app frame's culprit line (see EventBuilder#attach_source_context).
      # Defaults on so a snippet shows up without extra setup, but this flag
      # alone isn't the real protection against sending proprietary source
      # code somewhere it shouldn't go: ForgeOps' own per-project setting is
      # the durable, server-enforced off switch, since it applies regardless
      # of what this flag happens to be set to on any given deployment, and
      # can't drift back on the way a local config value could. Turn this
      # off here too if this host app never wants that disk read attempted
      # in the first place.
      @capture_source_context = true
      # When an error comes from a database call (ActiveRecord::StatementInvalid and anything that
      # wraps one), send the names of the stored procedure, table and view its SQL touched, so an
      # issue says where to start looking. Names are identifiers, never values, which is why this
      # defaults on. capture_sql_statement is the separate, opt-in step of also sending the
      # statement itself, with every string and number replaced by "?"; off by default because
      # even a masked statement describes the customer's schema, and ForgeOps' own per-project
      # setting is what durably governs whether the server stores it. See SqlStatement.
      @capture_sql_objects = true
      @capture_sql_statement = false
      # Auto-instruments every request the moment the gem loads, the same "on unless you turn it
      # off" default error tracking itself already has; nothing else in this gem is opt-in. See
      # ForgeOpsTracker::Middleware::SessionTracking for what this actually wraps.
      @track_sessions = true
      @session_flush_interval = 60
      # Auto-instruments every request the same "on unless you turn it off" default as
      # track_sessions above; see Railtie's own comment for exactly what this subscribes to.
      @track_performance = true
      @performance_flush_interval = 60
      # Auto-detects the current user via Warden (env["warden"].user; Devise mounts Warden
      # automatically, so this covers Devise apps too, but works for any Warden-based auth, not
      # just Devise specifically) the same "on unless you turn it off" default every other
      # automatic instrumentation flag above already has. See
      # ForgeOpsTracker::Middleware::UserContext for how, and ForgeOpsTracker.set_user for the
      # manual override/fallback when there's no Warden at all or its guess isn't right.
      @track_current_user = true
      # Auto-instruments SQL queries, controller actions, and outgoing Net::HTTP requests as
      # breadcrumbs the same "on unless you turn it off" default every other automatic
      # instrumentation flag above already has. See ForgeOpsTracker::Middleware::BreadcrumbContext
      # for the per-request buffer this gates, and ForgeOpsTracker.add_breadcrumb for adding one by
      # hand regardless of this flag (the manual API isn't gated by it: an app that wants only its
      # own hand-added breadcrumbs, with none of the automatic ones, turns this off and still gets
      # add_breadcrumb).
      @track_breadcrumbs = true
      # Oldest entry dropped once this many have accumulated in a single request: the same
      # "bounded ring buffer, not an unbounded log" reasoning sdks/typescript's own
      # Configuration#maxBreadcrumbs already documents, so a request that runs a very large number
      # of queries doesn't grow the trail (and the payload it rides in) without bound.
      @max_breadcrumbs = 30
      # Recorded from the same two instrumentation points that already exist for other reasons
      # (the perform.active_job subscription, Net::HTTP's own Timing#request): a job whose perform
      # raised, or an outbound call that raised or came back 5xx. On by default, independently of
      # track_performance/track_breadcrumbs, the same "several genuinely independent mechanisms
      # recorded from the same instrumentation point" pattern breadcrumbs already established at
      # both of those exact call sites.
      @track_failures = true
      @failure_event_flush_interval = 60
      # No track_metrics/track_infrastructure boolean the way track_sessions/track_performance
      # each have one: those gate automatic instrumentation that's on unless you turn it off;
      # capture_metric/capture_infrastructure_metric are explicit calls the customer's own code
      # chooses to make at all, so there's no "automatic behavior" for a flag to disable. Only
      # the flush interval needs a knob.
      @metric_flush_interval = 60
      @infrastructure_metric_flush_interval = 60
      # How often the Sidekiq/Solid Queue/Puma stats reporters poll and report their own gauge
      # readings (queue depth, worker counts, Puma backlog/threads/pool capacity). Gated by
      # track_performance, same as controller/job/query/http timing: one flag for "automatically
      # instrument this app's own operational data," reused rather than adding a separate boolean
      # per new automatic instrumentation source this gem grows.
      @gauge_poll_interval = 60
      # Auto-instruments controller actions, SQL queries, outgoing Net::HTTP requests, and Redis
      # calls into a nested per-request span tree, the same "on unless you turn it off" default
      # every other automatic instrumentation flag above already has. See
      # ForgeOpsTracker::Middleware::SpanTracing for the per-request buffer this gates, and
      # ForgeOpsTracker.span for wrapping a customer's own service-level code by hand so it shows
      # up as a real nested layer (e.g. "PaymentService#charge") rather than its database/HTTP
      # calls appearing to hang directly off the controller root. Whether this ever actually
      # reaches the server is a completely separate question from whether it's on: distributed
      # tracing is a plan-gated feature (see Api::V1::SpansController), enforced server-side the
      # same way every other ingestion endpoint already is, not by this client-side flag.
      @track_tracing = true
      # Only a request whose own total duration is at least this slow ever gets sent at all: see
      # SpanBuffer#slow?/Middleware::SpanTracing's own comment for why that decision happens
      # entirely client-side, before a single byte goes over the wire, rather than sending every
      # trace and letting the server decide. 1 second is a deliberately conservative default (most
      # web apps consider anything near that already a bad user experience), not tied to any
      # PerformanceSample-derived threshold elsewhere in this gem: those describe a trend across
      # many requests, this describes a single one being outright slow.
      @trace_capture_threshold_ms = 1_000
      # Opt-in: for a SELECT on PostgreSQL that took at least explain_threshold_ms, ask Postgres for
      # its plan (plain EXPLAIN, never EXPLAIN ANALYZE, so the query is never run again) and send
      # it, masked, so ForgeOps can show why the query was slow. Off by default because it runs one
      # extra statement against the app's own database. See QueryExplainer for exactly what it
      # does and doesn't do, and its rate limits.
      @explain_slow_queries = false
      @explain_threshold_ms = 500
      # Adds a W3C `traceparent` header (https://www.w3.org/TR/trace-context/) to every outbound
      # Net::HTTP request made during a request, so the service on the other end can continue this
      # request's trace instead of starting its own (see Integrations::NetHTTP). On by default, the
      # same as every other automatic behavior here, and independent of track_tracing: the header
      # carries the trace id that links an error here to an error there, which is useful with or
      # without spans. Never overwrites a traceparent the request already has.
      @propagate_traces = true
      # Which outbound hosts get that header. nil (the default) means every host. Otherwise an
      # Array of Strings and/or Regexps: a String matches that exact host or any subdomain of it
      # ("example.com" matches "example.com" and "api.example.com", but not "badexample.com"), a
      # Regexp is matched against the host. Worth narrowing for an app that calls third-party APIs
      # which reject unknown headers, or that shouldn't learn this app's trace ids at all.
      @trace_propagation_targets = nil
      # Sends one ChangeSnapshot per process at startup (Ruby version, locked gem versions, the
      # current migration version), which ForgeOps diffs against the previous boot's to record what
      # changed between deploys. On by default, like every other automatic behavior here.
      @detect_changes = true
      # Whether that snapshot also lists the names of this process's environment variables, so an
      # added or removed variable shows up as a change. Off by default: names only, never values,
      # but even names can describe more about an app than some teams want to share. See
      # ChangeSnapshot::ENV_VAR_DENYLIST for the host-specific names that are always left out.
      @track_env_var_names = false
      # Off by default. On, nothing this gem sends carries free text that could hold personal or
      # health data: no error message (a message_fingerprint is sent instead, so errors still
      # group), no breadcrumbs, no request path, no SQL statement, no source context, no user email
      # or username, no job failure message, and outbound HTTP spans named by method and host only.
      # See StrictPrivacy for every rule. FORGE_OPS_STRICT_PRIVACY=true turns it on from the
      # environment; setting it here wins over that.
      @strict_privacy = self.class.env_flag(ENV["FORGE_OPS_STRICT_PRIVACY"])
      # Context and tag keys strict privacy still sends (only plain string, number or boolean
      # values under exactly these top-level keys), e.g. %w[error_code feature]. Empty by default,
      # so nothing from context or tags goes out. FORGE_OPS_PRIVACY_ALLOWED_FIELDS=error_code,feature
      # sets it from the environment.
      self.privacy_allowed_fields = ENV["FORGE_OPS_PRIVACY_ALLOWED_FIELDS"].to_s.split(",")
    end

    # Accepts an Array of names or one comma-separated String; always kept as stripped Strings.
    def privacy_allowed_fields=(fields)
      fields = fields.split(",") if fields.is_a?(String)
      @privacy_allowed_fields = Array(fields).map { |field| field.to_s.strip }.reject(&:empty?)
    end

    # Whether an outbound request to host should carry a traceparent header; see
    # propagate_traces/trace_propagation_targets above. Case-insensitive, since hostnames are.
    def propagate_trace_to?(host)
      return false unless propagate_traces
      return true if trace_propagation_targets.nil?

      host = host.to_s.downcase
      Array(trace_propagation_targets).any? do |target|
        case target
        when Regexp
          target.match?(host)
        else
          target = target.to_s.downcase.delete_prefix(".")
          !target.empty? && (host == target || host.end_with?(".#{target}"))
        end
      end
    end

    def api_key
      parsed_dsn&.user
    end

    # The ingestion URL with credentials stripped out (they travel as the
    # Authorization header instead, not embedded in the request URI).
    def ingestion_uri
      return nil unless parsed_dsn

      uri = parsed_dsn.dup
      uri.user = nil
      uri.password = nil
      uri
    end

    # Same host and api_key as ingestion_uri, a sibling path under the same DSN rather than a
    # second DSN to configure; the DSN's own path is always /api/v1/events (what ForgeOps issues
    # to every project), so the session-checkins endpoint is derived by substitution.
    def session_checkins_uri
      uri = ingestion_uri
      return nil unless uri

      uri = uri.dup
      uri.path = uri.path.sub(%r{/events\z}, "/session_checkins")
      uri
    end

    # Same substitution as session_checkins_uri above, its own sibling path under the same DSN.
    def performance_samples_uri
      uri = ingestion_uri
      return nil unless uri

      uri = uri.dup
      uri.path = uri.path.sub(%r{/events\z}, "/performance_samples")
      uri
    end

    def custom_metrics_uri
      uri = ingestion_uri
      return nil unless uri

      uri = uri.dup
      uri.path = uri.path.sub(%r{/events\z}, "/custom_metrics")
      uri
    end

    def infrastructure_metrics_uri
      uri = ingestion_uri
      return nil unless uri

      uri = uri.dup
      uri.path = uri.path.sub(%r{/events\z}, "/infrastructure_metrics")
      uri
    end

    def failure_events_uri
      uri = ingestion_uri
      return nil unless uri

      uri = uri.dup
      uri.path = uri.path.sub(%r{/events\z}, "/failure_events")
      uri
    end

    def spans_uri
      uri = ingestion_uri
      return nil unless uri

      uri = uri.dup
      uri.path = uri.path.sub(%r{/events\z}, "/spans")
      uri
    end

    def query_plans_uri
      sibling_uri("/query_plans")
    end

    def changes_uri
      sibling_uri("/changes")
    end

    def change_snapshots_uri
      sibling_uri("/change_snapshots")
    end

    def enabled?
      configured? && environment_enabled?
    end

    # Whether a usable DSN is set, regardless of environment.
    def configured?
      !blank?(dsn) && !blank?(api_key)
    end

    # The one-line warning ForgeOpsTracker.warn_if_environment_disabled logs when a DSN is set but
    # this environment isn't one that sends, or nil when there's nothing to warn about (no DSN, or
    # the environment is enabled).
    def disabled_environment_warning
      return nil if !configured? || environment_enabled?

      enabled = enabled_environments.map(&:to_s)
      enabled = enabled.empty? ? "none" : enabled.join(", ")
      "[ForgeOps] Not sending: this environment is \"#{environment}\", and only #{enabled} are enabled. " \
        "Set FORGE_OPS_ENVIRONMENT=production (or add \"#{environment}\" to enabled_environments) to send from here."
    end

    # FORGE_OPS_ENVIRONMENT, then RAILS_ENV, then RACK_ENV, then "production". Defaulting to
    # "production" means a plain Ruby or Rack process that only sets a DSN actually sends; a Rails
    # app gets Rails.env from the Railtie instead (unless FORGE_OPS_ENVIRONMENT is set), so
    # development and test stay quiet there, with one warning at boot when a DSN is set.
    def self.resolve_environment(env = ENV)
      [ env["FORGE_OPS_ENVIRONMENT"], env["RAILS_ENV"], env["RACK_ENV"] ].find { |value| value && !value.strip.empty? } || "production"
    end

    # "true", "1", "yes" or "on" (any case) is on; anything else, or unset, is off.
    def self.env_flag(value)
      %w[true 1 yes on].include?(value.to_s.strip.downcase)
    end

    private
      def environment_enabled?
        enabled_environments.map(&:to_s).include?(environment.to_s)
      end

      # Same substitution every *_uri method above spells out by hand: a sibling path under the
      # DSN's own /api/v1/events.
      def sibling_uri(path)
        uri = ingestion_uri
        return nil unless uri

        uri = uri.dup
        uri.path = uri.path.sub(%r{/events\z}, path)
        uri
      end

      def parsed_dsn
        return nil if blank?(dsn)

        @parsed_dsn ||= URI.parse(dsn)
      rescue URI::InvalidURIError
        nil
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def safe_hostname
        Socket.gethostname
      rescue StandardError
        nil
      end
  end
end
