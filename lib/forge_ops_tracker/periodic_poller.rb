module ForgeOpsTracker
  # A small shared background-thread loop for the Sidekiq/Solid Queue/Puma stats reporters (see
  # integrations/): unlike PerformanceFlusher and the two metric buffers, which genuinely differ
  # in what they buffer and are kept as separate sibling classes on purpose (see
  # InfrastructureMetricBuffer's own comment), these three reporters only differ in *what they
  # poll*, not *how they poll it*: lazily start a thread on first use (so a forked worker gets
  # its own live thread regardless of when it forked relative to load, same reasoning
  # PerformanceFlusher's own lazy start documents), sleep the interval, call the block, rescue and
  # log so one bad tick never kills the loop, forever. Genuinely mechanical enough across all
  # three to share, unlike those.
  #
  # No at_exit flush: unlike the flushers/buffers, which hold real accumulated data that would
  # otherwise be lost, a gauge reading skipped on process exit is simply the same as one skipped
  # because the interval hadn't ticked yet: nothing to lose.
  class PeriodicPoller
    def self.start(interval, logger: nil, &block)
      new(interval, logger: logger, &block).tap(&:start)
    end

    def initialize(interval, logger: nil, &block)
      @interval = interval
      @logger = logger
      @block = block
      @mutex = Mutex.new
      @thread = nil
    end

    def start
      return if @thread&.alive?

      @mutex.synchronize do
        return if @thread&.alive?

        @thread = Thread.new { run }
        @thread.abort_on_exception = false
      end
      self
    end

    private
      def run
        loop do
          sleep @interval
          @block.call
        rescue StandardError => e
          @logger&.debug { "[ForgeOpsTracker] periodic poller error: #{e.class}: #{e.message}" }
        end
      end
  end
end
