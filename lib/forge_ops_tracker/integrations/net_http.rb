module ForgeOpsTracker
  module Integrations
    module NetHTTP
      # Times every outbound Net::HTTP call, applied once via Net::HTTP.prepend(Timing) from
      # Railtie. Ruby's standard library has no ActiveSupport::Notifications instrumentation of
      # its own for outbound HTTP the way it does for ActiveRecord/ActionController, so wrapping
      # #request directly is the only hook available; most other HTTP client libraries in the Ruby
      # ecosystem (Faraday's own net_http adapter, HTTParty, RestClient) ultimately call through
      # Net::HTTP too, so this covers those as a side effect without needing a wrapper per library.
      #
      # transaction_name is "<HTTP method> <host>", not the full URL: a request's own path or
      # query string could carry an id or a token, the same low-cardinality/no-secrets-in-a-label
      # reasoning every other transaction_name in this system already follows.
      #
      # Known, honest gap, confirmed directly against Net::HTTP's own source and real behavior, not
      # assumed: Net::HTTP.get_response and the Net::HTTP.start { |http| ... } block form both open
      # the TCP connection inside #start, *before* the block (and so before #request, the only
      # method this wraps) ever runs, so a connection-refused/DNS-failure error raised during that
      # setup is structurally invisible here, for timing, breadcrumbs, and the failure detection
      # below alike (a pre-existing limitation this round's own test suite is what actually
      # surfaced, not something newly introduced). Net::HTTP.new(...).request(...), the other
      # common calling convention (no explicit #start at all), is different and unaffected:
      # confirmed directly that Net::HTTP connects lazily, inside #request itself, the first time
      # it's called on a not-yet-started instance, so that path's own connection failures are
      # caught exactly like any other #request failure.
      #
      # Also propagates the current request's trace to the service being called, as a W3C
      # `traceparent` header (see TraceParent, and Configuration#propagate_traces/
      # trace_propagation_targets for turning it off or narrowing it to specific hosts). The
      # header's parent id is this outbound call's own span id, generated before the call is made
      # (the span itself can only be recorded afterward, once its duration is known) and then
      # recorded with that exact id, so the downstream service's root span points at a span that
      # really exists in this trace. Only inside a request (a RequestState to take the trace id
      # from); a background job or a console session has no trace to continue.
      module Timing
        # The guard (return super unless ...) skips timing, but the ensure block below still runs
        # on every exit path regardless, same as any ensure; start staying nil is what actually
        # skips recording there, not a second guard duplicating this one.
        def request(req, body = nil, &block)
          configuration = ForgeOpsTracker.configuration
          return super unless (configuration.track_performance || configuration.track_breadcrumbs || configuration.track_failures || configuration.track_tracing || configuration.propagate_traces) && configuration.enabled?

          span_id = ForgeOpsTracker::TraceParent.generate_span_id
          propagate_trace(req, span_id, configuration)
          start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          response = super
        rescue StandardError => e
          # Only track_failures below needs the actual exception object (for error_class/
          # error_message); everything else keys off response staying nil, already true on this
          # path without capturing anything. re-raised unchanged: this gem must never swallow or
          # alter what the host app's own call to Net::HTTP#request would have raised.
          raised_error = e
          raise
        ensure
          if start
            duration_ms = (::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - start) * 1000.0
            # Computed once, unconditionally, not separately inside each flag-gated block below:
            # both the breadcrumb and track_failures sections need it, and a value only ever
            # assigned inside one conditional branch but read from another relies on Ruby's own
            # "a local is declared the moment its assignment is lexically parsed, regardless of
            # whether that branch actually ran" scoping, a real but easy-to-break-on-reorder
            # subtlety not worth the risk here.
            status = response&.code&.to_i
            if configuration.track_performance
              Railtie.performance_flusher.record(transaction_name: "#{req.method} #{address}", duration_ms: duration_ms, kind: "http")
            end
            # The same "method + host, never the full path/query string" reasoning
            # transaction_name above already follows: a URL's own path or query could carry an id
            # or a token, and this is a breadcrumb message, not a value this gem controls the
            # cardinality of. Mirrors sdks/typescript's own fetch/xhr breadcrumbs: category
            # "http", status + duration_ms in data, level "warning" for a non-2xx/3xx response.
            if configuration.track_breadcrumbs
              # No status at all means the request itself raised (a timeout, a connection
              # refused, ...) before a response ever came back: worth "error", not the misleading
              # "info" a bare status-based check would default a nil status to, the same "the
              # request truly failed" case sdks/typescript's own fetch breadcrumb catch block
              # marks "error" for.
              level = if status.nil?
                "error"
              elsif status >= 400
                "warning"
              else
                "info"
              end
              ForgeOpsTracker.add_breadcrumb(
                "#{req.method} #{address}",
                category: "http",
                level: level,
                data: { status: status, duration_ms: duration_ms.round(1) }.compact
              )
            end
            # Independent of track_performance/track_breadcrumbs above, same "several genuinely
            # independent mechanisms recorded from the same instrumentation point" pattern this
            # exact call site already established for breadcrumbs. A failure is the request
            # raising, or a 5xx: not a 4xx, the identical distinction the breadcrumb level just
            # above already draws between "the dependency is unhealthy" (worth "error"/failure)
            # and "the dependency responded, just not with success" (only "warning").
            if configuration.track_failures && (status.nil? || status >= 500)
              Railtie.failure_event_buffer.record(
                kind: "dependency", transaction_name: "#{req.method} #{address}",
                error_class: raised_error&.class&.name, error_message: raised_error&.message
              )
            end
            # A leaf span, the same "parented onto whatever's currently open, never touches the
            # stack itself" shape the sql.active_record subscription's own span recording already
            # takes: an outbound HTTP call has no children of its own to nest anything under
            # either.
            if configuration.track_tracing && (buffer = Thread.current[:forge_ops_tracker_spans])
              # duration_ms itself is exact (computed from the monotonic clock above); started_at
              # here is only derived from it (now minus duration), an approximation off the wall
              # clock rather than a second real timestamp captured at the top of this method - a
              # few milliseconds of drift on where the bar starts in a waterfall, never on how long
              # it actually took.
              start_time = ::Time.now.utc - (duration_ms / 1000.0)
              buffer.record(
                span_id: span_id, name: "#{req.method} #{address}", kind: "http",
                started_at: start_time, duration_ms: duration_ms, data: { status: status }.compact
              )
            end
          end
        end

        private
          # Leaves a traceparent the caller already set alone: whoever set it explicitly knows
          # better than this gem which trace the call belongs to. Never raises, since a failure to
          # add a header must never stop the host app's own request from going out.
          def propagate_trace(req, span_id, configuration)
            state = ForgeOpsTracker::Middleware::RequestContext.current
            return unless state && configuration.propagate_trace_to?(address)
            return if req[ForgeOpsTracker::TraceParent::HEADER]

            req[ForgeOpsTracker::TraceParent::HEADER] = ForgeOpsTracker::TraceParent.build(trace_id: state.trace_id, span_id: span_id)
          rescue StandardError
            nil
          end
      end
    end
  end
end
