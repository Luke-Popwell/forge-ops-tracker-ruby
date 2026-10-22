require "thread"

module ForgeOpsTracker
  # Collects individual ForgeOpsTracker.capture_metric calls in-process and periodically flushes
  # them as one batch, rather than one network call per capture: the same "lazily start a
  # background thread on first use" pattern SessionFlusher/PerformanceFlusher already use, so each
  # forked Puma/Passenger worker gets its own fresh thread instead of inheriting a dead one across
  # fork. Unlike those two, this collects a *list* of individually-meaningful entries rather than
  # summing them into buckets: a customer's own signup or payment is exactly the kind of thing
  # they'll want a genuinely accurate count/sum of later, not something to pre-aggregate away
  # client-side, so CustomMetricsController stores one row per entry as-is.
  class MetricBuffer
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
      @outcome = FlushOutcome.new(configuration, "metrics")

      # Flushes whatever's already buffered on a normal process exit, so the last partial window
      # isn't silently dropped; same reasoning every other buffer/flusher in this gem documents.
      at_exit { flush }
    end

    def record(metric_name:, value:)
      return false unless keepable?(value)

      ensure_worker_started

      @mutex.synchronize do
        return false if @entries.size >= MAX_ENTRIES

        @entries << {
          metric_name: metric_name, value: value,
          environment: configuration.environment.to_s, release: configuration.release,
          recorded_at: Time.now.utc.iso8601
        }
      end
    end

    # Snapshots and resets the buffered entries, then delivers them as one batch. A delivery that
    # failed for now keeps every entry where it is rather than resetting, so the next flush's batch
    # just grows instead of losing what was already buffered (a rejected batch, or one that failed
    # FlushOutcome::MAX_FAILED_FLUSHES flushes in a row, is dropped instead); same reasoning
    # SessionFlusher#flush already documents, including the same small, accepted race (an entry recorded during the
    # in-flight HTTP request gets folded into this snapshot's own reset rather than kept for the
    # next one) that class already lives with, for the same reason: simple and consistent beats a
    # cleverer dedup that would only trade one rare edge case for a subtler one.
    def flush
      snapshot = nil

      @mutex.synchronize do
        return if @entries.empty?
        snapshot = @entries.dup
      end

      return unless @outcome.release?(client.deliver_metrics(snapshot))

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
          sleep configuration.metric_flush_interval
          flush
        rescue StandardError => e
          configuration.logger&.debug { "[ForgeOpsTracker] metric flush thread error: #{e.class}: #{e.message}" }
        end
      end
  end
end
