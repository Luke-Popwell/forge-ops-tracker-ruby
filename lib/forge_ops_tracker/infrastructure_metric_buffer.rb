require "thread"

module ForgeOpsTracker
  # Collects individual ForgeOpsTracker.capture_infrastructure_metric readings in-process and
  # periodically flushes them as one batch, same shape as MetricBuffer (a sibling class, not a
  # shared base; this gem keeps SessionFlusher/PerformanceFlusher as separate, independently-
  # readable classes despite their own similar shape too, and these two follow that precedent).
  # Its main real caller is a short-lived cron/script process that exits right after a handful of
  # capture calls, so the at_exit flush below is what actually matters in practice; the periodic
  # background-thread timer still runs for a long-lived process that chooses to call this
  # continuously instead, but rarely gets the chance to fire in the cron case.
  class InfrastructureMetricBuffer
    # Once this many entries are buffered, further ones are dropped until a flush lets go of them:
    # an unreachable server fails every flush, and an uncapped buffer would keep growing until
    # FlushOutcome gives up on the batch. Dropping the newest rather than the oldest keeps the entries a flush
    # is delivering at the front of the array, which is what makes removing exactly them exact.
    MAX_ENTRIES = 1000

    def initialize(configuration, client: Client.new(configuration))
      @configuration = configuration
      @client = client
      @mutex = Mutex.new
      @entries = []
      @thread = nil
      @outcome = FlushOutcome.new(configuration, "infrastructure metrics")

      at_exit { flush }
    end

    def record(metric_name:, value:, hostname:)
      return false unless keepable?(value)

      ensure_worker_started

      @mutex.synchronize do
        return false if @entries.size >= MAX_ENTRIES

        @entries << { metric_name: metric_name, value: value, hostname: hostname, recorded_at: Time.now.utc.iso8601 }
      end
    end

    # Same reset-on-success/keep-on-failure/drop-on-rejection contract as MetricBuffer#flush; see that class's own
    # comment for the accepted race this shares with it.
    def flush
      snapshot = nil

      @mutex.synchronize do
        return if @entries.empty?
        snapshot = @entries.dup
      end

      return unless @outcome.release?(client.deliver_infrastructure_metrics(snapshot))

      # Exactly the entries just sent: anything recorded while the request was in flight sits
      # after them and stays for the next flush (resetting the whole array here lost it).
      @mutex.synchronize { @entries.shift(snapshot.size) }
    end

    private
      attr_reader :configuration, :client

      # A NaN or infinite value is not valid JSON and would make the server reject the whole batch.
      def keepable?(value)
        value.is_a?(Numeric) && value.to_f.finite?
      end

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
          sleep configuration.infrastructure_metric_flush_interval
          flush
        rescue StandardError => e
          configuration.logger&.debug { "[ForgeOpsTracker] infrastructure metric flush thread error: #{e.class}: #{e.message}" }
        end
      end
  end
end
