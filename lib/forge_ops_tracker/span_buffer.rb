require "securerandom"

module ForgeOpsTracker
  # Accumulates one request's own nested call tree in-process; the tracing analog to
  # BreadcrumbBuffer's per-thread trail. ForgeOpsTracker::Middleware::SpanTracing resets this to a
  # fresh buffer at the start of every request, with a freshly generated root span_id and the
  # request's own trace_id (and remote parent span id, when the request continued a trace another
  # service started; see RequestState), and reads it back once the request is over to decide
  # whether this trace is worth sending at all (see that middleware's own comment for exactly where
  # and why). trace_id/parent_span_id are passed in rather than generated here: the trace_id
  # belongs to the request, not to span tracing, since an error event carries it too, even with
  # tracing off, and the two have to agree for ForgeOps to link them.
  #
  # The stack exists so nesting can be reconstructed correctly even though most of what's recorded
  # here (a query, an outbound HTTP call, a Redis call) only has a start+duration known *after* the
  # fact, not a real "this span is now open" moment the way a manually-wrapped ForgeOpsTracker.span
  # block has. Whatever's on top of the stack at the moment a leaf span is recorded is that leaf's
  # real parent: the nearest currently-open span, whether that's the request's own root, or a
  # service-level span a customer wrapped their own code in. The root span_id is pushed onto the
  # stack immediately, at construction, specifically so every span recorded before the controller
  # action itself finishes (which is every one of them, since process_action.action_controller's
  # own subscription only fires once the whole action, including everything nested inside it, has
  # already run) naturally nests under it without the root having to exist as a real recorded span
  # first.
  class SpanBuffer
    attr_reader :trace_id, :root_span_id, :parent_span_id, :spans

    def initialize(trace_id: SecureRandom.hex(16), parent_span_id: nil)
      @trace_id = trace_id
      @parent_span_id = parent_span_id
      @root_span_id = SecureRandom.hex(8)
      @spans = []
      @stack = [ @root_span_id ]
      @root_duration_ms = nil
    end

    def current_parent_id
      @stack.last
    end

    def push(span_id)
      @stack.push(span_id)
    end

    def pop
      @stack.pop
    end

    # root: true only for the one call that records the request's own root span (see Railtie's
    # process_action.action_controller subscription): takes its parent from the incoming
    # traceparent header's span id instead of the stack, since by the time that fires, the root's
    # own span_id has already been popped off it (there's nothing left on it to read back as "the
    # parent" at that point, correctly: nothing inside this process is the root's parent). nil for
    # a request that started its own trace; the calling service's span otherwise, which ForgeOps
    # treats as a remote parent because it's never part of this same batch.
    def record(span_id:, name:, kind:, started_at:, duration_ms:, data: {}, root: false)
      parent_span_id = root ? @parent_span_id : current_parent_id
      spans << {
        span_id: span_id, parent_span_id: parent_span_id, name: name, kind: kind,
        started_at: started_at.utc.iso8601(3), duration_ms: duration_ms, data: data
      }
      @root_duration_ms = duration_ms if root
    end

    # nil (never sent) until the root span has actually been recorded; a request that somehow never
    # fires process_action.action_controller at all (a request Rails itself never routes) has no
    # duration to compare against a threshold, so it's never mistakenly treated as "slow."
    def slow?(threshold_ms)
      @root_duration_ms && @root_duration_ms >= threshold_ms
    end

    # Whether the root span was ever recorded at all. Middleware::SpanTracing only sends an errored
    # request's trace when this is true: without the root, every other span in the buffer points at
    # a parent that was never recorded, which ForgeOps would misread as a remote parent in some
    # other service rather than a missing root in this one.
    def root_recorded?
      !@root_duration_ms.nil?
    end
  end
end
