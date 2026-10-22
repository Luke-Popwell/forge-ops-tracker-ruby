require "digest"

module ForgeOpsTracker
  # What Configuration#strict_privacy changes in everything this gem sends, for apps that can't let
  # personal or health data leave their own servers. With it on, only structured facts go out (the
  # error's class, its stack frames, release, environment, server, which request it happened in,
  # timings and counts); free text, which is where a name, an email or a diagnosis hides, never
  # leaves this process: no error message, no breadcrumbs, no raw request path, no SQL statement,
  # no source context, no user email or username, and only the context/tag keys listed in
  # Configuration#privacy_allowed_fields.
  #
  # The same rules as the server's own StrictPrivacy (app/services/strict_privacy.rb), which
  # applies them again on arrival when the project's Strict privacy setting is on;
  # sdks/strict_privacy_vectors.json pins the results both have to agree on, byte for byte.
  module StrictPrivacy
    FINGERPRINT_LENGTH = 32

    # ASCII "word" characters; boundaries are defined against these, the same in every SDK, so
    # Ruby's own idea of a word never changes the result.
    WORD = "A-Za-z0-9_".freeze
    EMAIL = /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/
    # A quoted value (KeyError: 'Jane Doe') is data, not the shape of the error. Single quotes only open
    # and close at a word boundary, so a contraction (Couldn't) or the `email' style never starts one.
    DOUBLE_QUOTED = /"[^"\r\n]*"/
    SINGLE_QUOTED = /(?<![#{WORD}])'[^'\r\n]*'(?![#{WORD}])/
    HEX_OBJECT_ID = /0x[0-9a-fA-F]{4,}/
    UUID = /(?<![#{WORD}])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![#{WORD}])/
    NUMBER = /(?<![#{WORD}])[0-9]+(?![#{WORD}])/

    # Span data that's structure, not content: the masked statement and which database it ran on.
    SPAN_DATA_KEYS = %w[db.statement db.system].freeze
    HTTP_METHOD = /\A(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(\S+)/i
    SCHEME = %r{\A[a-z][a-z0-9+.-]*://}i
    ROUTE_PARAMETER = /\A(?::.+|\{.+\}|<.+>|\[.+\]|\*.*)\z/

    # Error event fields that are never sent, and the per-frame source context.
    EVENT_FIELDS_DROPPED = %i[message breadcrumbs endpoint sql_statement].freeze
    SOURCE_CONTEXT_FIELDS = %i[context_line pre_context post_context].freeze

    module_function

    # The message with emails, quoted values, hex object ids, UUIDs and standalone numbers replaced, in
    # that order (sdks/STRICT_PRIVACY.md).
    def normalize_message(message)
      message.to_s.gsub(EMAIL, "<email>").gsub(DOUBLE_QUOTED, "<str>").gsub(SINGLE_QUOTED, "<str>")
        .gsub(HEX_OBJECT_ID, "0x").gsub(UUID, "<uuid>").gsub(NUMBER, "<n>")
    end

    # Lets ForgeOps group errors without ever seeing their message: the first 32 hex characters of
    # the SHA-256 of the normalized message's UTF-8 bytes, so two messages that differ only in ids
    # hash the same, and nothing about the text can be read back from it.
    #
    # A message labelled binary (some C extensions raise with one) is read as the UTF-8 it almost
    # always is, rather than converted byte by byte, which would turn every non-ASCII character into
    # replacement characters and hash differently from the same text arriving as UTF-8.
    def message_fingerprint(message)
      normalized = normalize_message(message)
      normalized = normalized.dup.force_encoding(Encoding::UTF_8) if normalized.encoding == Encoding::BINARY
      normalized = normalized.encode(Encoding::UTF_8, invalid: :replace, undef: :replace) unless normalized.encoding == Encoding::UTF_8
      Digest::SHA256.hexdigest(normalized.scrub)[0, FINGERPRINT_LENGTH]
    end

    # An error event payload (EventBuilder#build's shape, symbol keys) reduced to what strict
    # privacy sends. message is sent as "" alongside message_fingerprint, exactly what the server
    # stores for a strict project.
    def event(payload, allowed_fields: [])
      payload.reject { |key, _value| EVENT_FIELDS_DROPPED.include?(key) }.merge(
        message: "",
        message_fingerprint: message_fingerprint(payload[:message]),
        transaction_name: transaction_name(payload[:transaction_name]),
        context: allowed(payload[:context], allowed_fields),
        tags: allowed(payload[:tags], allowed_fields),
        user: user(payload[:user]),
        backtrace: Array(payload[:backtrace]).map { |frame| frame.reject { |key, _value| SOURCE_CONTEXT_FIELDS.include?(key) } }
      ).compact
    end

    # A background job or dependency failure: its class is kept, its message never is, and its
    # transaction_name goes through transaction_name above.
    def failure_event(entry)
      entry.reject { |key, _value| key == :error_message }.merge(transaction_name: transaction_name(entry[:transaction_name]))
    end

    # A trace's span: an outbound call's name keeps its method and host, never its path or query,
    # and its data keeps only the masked statement and database system. data is left out entirely
    # when nothing is left of it, the same as the server does.
    def span(span)
      data = (span[:data] || {}).select { |key, _value| SPAN_DATA_KEYS.include?(key.to_s) }
      span.merge(name: span_name(span[:name]), data: (data unless data.empty?)).compact
    end

    # "GET https://api.example.com/patients/42?x=1" or "GET api.example.com/patients/42" becomes
    # "GET api.example.com". A bare path ("/patients/42"), or a method and a path
    # ("PUT /orders/17/items"), goes through the path rule, like a page path. A name that's neither
    # ("OrdersController#create", "patients#show") is kept.
    def span_name(name)
      return strict_path(name) if name.to_s.start_with?("/")

      match = name.to_s.match(HTTP_METHOD)
      return name unless match

      method = match[1].upcase
      target = match[2]
      return "#{method} #{strict_path(target)}" if target.start_with?("/")

      "#{method} #{host(target) || strict_path(target)}"
    end

    # Which request something happened in: a route or a controller action is kept, but a raw path
    # (what a request no route matched falls back to) keeps only its first segment, by the span name
    # rule.
    def transaction_name(name)
      name.nil? || name.to_s.empty? ? name : span_name(name)
    end

    # An outbound call's host, read by hand rather than with URI.parse (an address a parser rejects
    # must never be sent whole): what comes before the first "/", "?" or "#", without a scheme,
    # credentials (up to the last "@", since a password can hold one) or port. Only a host when the
    # address had a scheme or a port, or the name has a dot or is "localhost"; nil otherwise (a
    # relative path).
    def host(target)
      scheme = target.match?(SCHEME)
      authority = target.sub(SCHEME, "").split(%r{[/?#]}, 2).first.to_s.sub(/\A.*@/m, "")
      port = authority.match?(/:\d+\z/)
      host = authority.sub(/:\d+\z/, "")
      return nil if host.empty?

      host if scheme || port || host.include?(".") || host.casecmp?("localhost")
    end

    # A request or page path under strict privacy, with no query or fragment. A route template
    # ("/patients/:id/notes", "/patients/{id}", "users/<int:id>/", "/files/*path", "/posts/[slug]")
    # is kept as it is: its words are a developer's, and its parameters are already placeholders. A
    # raw path keeps only its first segment, and the rest becomes ":path": "/patients/jane-doe/12"
    # is "/patients/:path". Anything after the first segment of a raw path could name a person, and
    # no rule can tell a name from a word ("/patients/janedoe"). A first segment that holds a digit
    # or is over 40 characters is ":id" itself.
    def strict_path(path)
      path = path.to_s.split(/[?#]/, 2).first.to_s
      return path if route_template?(path)

      leading = path.start_with?("/") ? "/" : ""
      segments = path.split("/").reject(&:empty?)
      return "/" if segments.empty?

      first = segments.first.match?(/[0-9]/) || segments.first.length > 40 ? ":id" : segments.first
      "#{leading}#{first}#{"/:path" if segments.size > 1}"
    end

    # Whether any segment is a route parameter: ":id", "{id}", "<int:id>", "[slug]" or "*path".
    def route_template?(path)
      path.split("/").any? { |segment| segment.match?(ROUTE_PARAMETER) }
    end

    # Only top-level keys named in allowed_fields, and only plain values under them; nil (left out
    # of the payload) when nothing is left.
    def allowed(fields, allowed_fields)
      allowed_fields = Array(allowed_fields).map(&:to_s)
      return nil if allowed_fields.empty? || !fields.is_a?(Hash)

      kept = fields.each_with_object({}) do |(key, value), result|
        next unless allowed_fields.include?(key.to_s)
        next unless value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false

        result[key.to_s] = value
      end
      kept unless kept.empty?
    end

    # The user's id, as a string, and nothing else; nil when there's no id.
    def user(user)
      return nil unless user.is_a?(Hash)

      id = user[:id] || user["id"]
      { id: id.to_s } unless id.nil? || id.to_s.strip.empty?
    end
  end
end
