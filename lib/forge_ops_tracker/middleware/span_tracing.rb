module ForgeOpsTracker
  module Middleware
    # Gives every request its own fresh SpanBuffer (see that class for the stack/nesting
    # mechanics), the same "Thread.current, cleared in an ensure" shape BreadcrumbContext already
    # uses and for the identical reason: Puma reuses threads across requests, so a buffer left set
    # would leak one request's spans into a later, unrelated one handled on the same thread. The
    # buffer's trace_id and remote parent span id come from the request's RequestState, never
    # generated here, so a trace this sends and an error event from the same request always agree
    # on which trace they belong to (see RequestState for why that object is shared through the
    # Rack env rather than the thread-local RequestContext publishes: this middleware sits outside
    # that one, and runs first).
    #
    # The actual send-or-don't decision lives here, not in SpanBuffer or SpanQueue: only once
    # app.call returns does this middleware know the root span's own final duration (recorded by
    # Railtie's process_action.action_controller subscription, which fires from *inside* that
    # call, after every nested query/HTTP/Redis call has already run), so this is the first point
    # that can compare it against configuration.trace_capture_threshold_ms and decide the trace was
    # never worth sending in the first place: the entire reason a normal, fast request never costs
    # a single byte over the wire, unlike PerformanceSample's own always-on aggregate reporting.
    #
    # An errored request's trace is always sent too, however fast it was, since the waterfall of
    # what led up to an error is exactly what an issue page wants to show next to it. "Errored"
    # means the RequestState was marked by either path: an unhandled exception passing through
    # RequestContext on its way out, or ErrorSubscriber#report receiving a handled error during the
    # request. Both have already happened by the time this ensure runs; the unhandled one is only
    # *reported* later (by ActionDispatch::Executor, outside every middleware here), but it's
    # marked on the way through, which is what counts. Requires the root span to have been
    # recorded, see SpanBuffer#root_recorded? for why.
    class SpanTracing
      def initialize(app, configuration: ForgeOpsTracker.configuration)
        @app = app
        @configuration = configuration
      end

      def call(env)
        return app.call(env) unless configuration.track_tracing && configuration.enabled?

        state = RequestState.for(env)
        buffer = SpanBuffer.new(trace_id: state.trace_id, parent_span_id: state.parent_span_id)
        Thread.current[:forge_ops_tracker_spans] = buffer
        app.call(env)
      ensure
        if buffer && send_trace?(buffer, state)
          Railtie.span_queue.push(trace_id: buffer.trace_id, spans: outgoing_spans(buffer))
        end
        Thread.current[:forge_ops_tracker_spans] = nil
      end

      private
        attr_reader :app, :configuration

        def send_trace?(buffer, state)
          return true if buffer.slow?(configuration.trace_capture_threshold_ms)

          state.errored? && buffer.root_recorded?
        end

        # Under strict privacy, every span goes through StrictPrivacy.span: an outbound call named
        # by its method and host only, and no span data but the masked statement and db.system.
        def outgoing_spans(buffer)
          return buffer.spans unless configuration.strict_privacy

          buffer.spans.map { |span| StrictPrivacy.span(span) }
        end
    end
  end
end
