require "securerandom"

module ForgeOpsTracker
  # Reads and writes the W3C Trace Context `traceparent` header
  # (https://www.w3.org/TR/trace-context/), the vendor-neutral format for carrying one trace across
  # service boundaries: `00-<32 hex trace-id>-<16 hex parent-id>-<2 hex flags>`. Used in both
  # directions: Middleware::RequestContext parses an incoming one so this request continues the
  # caller's trace instead of starting its own, and Integrations::NetHTTP builds an outgoing one so
  # the next service along continues this request's.
  #
  # Deliberately strict on the way in, the same posture the spec itself asks receivers to take: a
  # malformed value, uppercase hex, the reserved version "ff", or an all-zero trace/parent id are
  # all treated as "no usable header at all" (parse returns nil and the request starts a fresh
  # trace), never half-trusted. A version this gem doesn't know yet is still accepted as long as
  # its first four fields have version 00's shape, which is exactly what the spec says a version-00
  # parser should do with a future version; version 00 itself must have exactly four fields.
  module TraceParent
    HEADER = "traceparent".freeze
    RACK_ENV_KEY = "HTTP_TRACEPARENT".freeze

    PATTERN = /\A(?<version>[0-9a-f]{2})-(?<trace_id>[0-9a-f]{32})-(?<parent_id>[0-9a-f]{16})-(?<flags>[0-9a-f]{2})(?<rest>-.*)?\z/
    INVALID_TRACE_ID = ("0" * 32).freeze
    INVALID_PARENT_ID = ("0" * 16).freeze

    # Always "01" (sampled) on the way out: this gem decides whether to actually send a trace only
    # once the request is over (see Middleware::SpanTracing), long after this header has already
    # gone out on an outbound call, so there's no honest earlier answer to give than "this may be
    # recorded." A downstream service is free to make its own decision either way.
    SAMPLED_FLAGS = "01".freeze

    module_function

    # Returns { trace_id:, parent_span_id: } for a usable header, nil for anything else (absent,
    # blank, malformed, or one of the explicitly invalid values above).
    def parse(value)
      return nil unless value.is_a?(String)

      match = PATTERN.match(value.strip)
      return nil unless match
      return nil if match[:version] == "ff"
      return nil if match[:version] == "00" && match[:rest]
      return nil if match[:trace_id] == INVALID_TRACE_ID || match[:parent_id] == INVALID_PARENT_ID

      { trace_id: match[:trace_id], parent_span_id: match[:parent_id] }
    end

    def build(trace_id:, span_id:)
      "00-#{trace_id}-#{span_id}-#{SAMPLED_FLAGS}"
    end

    # 32 lowercase hex characters, the W3C trace-id format; SecureRandom.hex already produces
    # lowercase, which is the only case the spec allows.
    def generate_trace_id
      SecureRandom.hex(16)
    end

    # 16 lowercase hex characters, the W3C parent-id (span id) format.
    def generate_span_id
      SecureRandom.hex(8)
    end
  end
end
