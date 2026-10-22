require "thread"

module ForgeOpsTracker
  # Same shape and reasoning as DeliveryQueue: a small in-process background thread + bounded
  # queue, so delivering a captured trace never adds latency to the very request it was just
  # measuring - the one thing that would be actively counterproductive here, blocking an already-
  # slow request even longer just to report that it was slow. One whole trace (a trace_id plus
  # every span belonging to it) is one queue entry, delivered as one client call, not batched
  # together with other traces the way PerformanceFlusher/FailureEventBuffer batch over a time
  # window: a trace is already a complete, immediately-relevant unit the moment a request
  # finishes, so it's delivered promptly rather than held for up to a full flush interval.
  class SpanQueue
    def initialize(configuration, client: Client.new(configuration))
      @configuration = configuration
      @client = client
      @queue = SizedQueue.new(configuration.queue_size)
      @mutex = Mutex.new
      @thread = nil
    end

    # Dropping a whole trace silently (never blocking the caller) if the queue is already full,
    # the same backpressure-must-never-reach-the-host-app posture DeliveryQueue#push already
    # documents; a burst of several slow requests at once must never stall a request that's
    # already been identified as slow even further.
    def push(trace_id:, spans:)
      ensure_worker_started
      @queue.push({ trace_id: trace_id, spans: spans }, true)
      true
    rescue ThreadError
      log { "span delivery queue full, dropping trace" }
      false
    end

    private
      attr_reader :configuration, :client

      def ensure_worker_started
        return if @thread&.alive?

        @mutex.synchronize do
          return if @thread&.alive?

          @thread = Thread.new { run }
          @thread.abort_on_exception = false
        end
      end

      def run
        loop do
          entry = @queue.pop
          client.deliver_spans(trace_id: entry[:trace_id], spans: entry[:spans])
        rescue StandardError => e
          log { "span delivery thread error: #{e.class}: #{e.message}" }
        end
      end

      def log
        configuration.logger&.debug { "[ForgeOpsTracker] #{yield}" }
      end
  end
end
