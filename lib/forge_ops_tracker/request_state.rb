module ForgeOpsTracker
  # Everything this gem knows about the current request that isn't already owned by one of the
  # older, single-purpose thread-locals (the user, the breadcrumb trail, the span buffer): which
  # trace it belongs to, which remote span called it (if any), what it's called, and whether it
  # errored. One instance per request, shared by every piece of this gem that needs any of those:
  #
  # - Middleware::RequestContext publishes it as a thread-local
  #   (Thread.current[:forge_ops_tracker_request_context]) for the duration of the request, so
  #   ErrorSubscriber#report, the start_processing.action_controller subscription, and the
  #   Net::HTTP integration can reach it (none of them are ever handed the Rack env).
  # - Middleware::SpanTracing reads the same instance's trace_id/parent_span_id for its SpanBuffer,
  #   and its errored? flag once the request is over.
  #
  # The trace_id exists for every request, not only when span tracing is on: it's also what an
  # error event carries so ForgeOps can link it to errors reported by other services taking part in
  # the same trace, which works on any plan and with track_tracing off entirely.
  #
  # Memoized in the Rack env (see .for) rather than created by one specific middleware and handed to
  # the other: SpanTracing sits *outside* RequestContext in the stack (RequestContext must be the
  # innermost of this gem's middlewares; see its own comment for why), so SpanTracing runs first and
  # needs the trace_id before RequestContext has run at all, then keeps needing this same object
  # after RequestContext's own ensure has already cleared the thread-local. Whichever of the two
  # reaches a given request first creates it; the other gets the identical instance back.
  class RequestState
    ENV_KEY = "forge_ops_tracker.request_state".freeze

    attr_reader :trace_id, :parent_span_id
    attr_accessor :transaction_name, :endpoint

    def self.for(env)
      env[ENV_KEY] ||= from_env(env)
    end

    # Continues the caller's trace when the request arrived with a usable W3C traceparent header,
    # remembering the caller's span as this request's remote parent; starts a fresh trace otherwise.
    def self.from_env(env)
      incoming = TraceParent.parse(env[TraceParent::RACK_ENV_KEY])
      if incoming
        new(trace_id: incoming[:trace_id], parent_span_id: incoming[:parent_span_id])
      else
        new
      end
    end

    def initialize(trace_id: TraceParent.generate_trace_id, parent_span_id: nil)
      @trace_id = trace_id
      @parent_span_id = parent_span_id
      @transaction_name = nil
      @endpoint = nil
      @errored = false
    end

    # Called from the start_processing.action_controller subscription (see Railtie), the earliest
    # point Rails names the controller/action handling this request: early enough that an error
    # reported partway through the action itself (Rails.error.handle/record) already carries both.
    def controller_started(payload)
      self.transaction_name = PerformanceInstrumentation.controller_transaction_name(payload)
      self.endpoint = PerformanceInstrumentation.controller_endpoint(payload)
    end

    def mark_errored!
      @errored = true
    end

    def errored?
      @errored
    end
  end
end
