require "thread"

module ForgeOpsTracker
  # Collects individual job/dependency failures in-process (see Railtie's own perform.active_job
  # subscription and Integrations::NetHTTP::Timing#request, the two places that actually call
  # #record) and periodically flushes them as one batch, the same shape MetricBuffer already uses
  # for the identical reason: a real failure's own detail (which job, what error) is exactly the
  # kind of thing worth an accurate individual record of, not something to pre-aggregate away the
  # way PerformanceFlusher's own count/sum/max buckets duration.
  class FailureEventBuffer
    # Same cap, and the same "drop the newest, not the oldest" reasoning, as MetricBuffer's own
    # MAX_ENTRIES: a burst of failures during an outage must not grow this without bound.
    MAX_ENTRIES = 1000

    def initialize(configuration, client: Client.new(configuration))
      @configuration = configuration
      @client = client
      @mutex = Mutex.new
      @entries = []
      @thread = nil
      @outcome = FlushOutcome.new(configuration, "failure events")

      # Flushes whatever's already buffered on a normal process exit, so the last partial window
      # isn't silently dropped; same reasoning every other buffer/flusher in this gem documents.
      at_exit { flush }
    end

    def record(kind:, transaction_name:, error_class: nil, error_message: nil)
      ensure_worker_started

      @mutex.synchronize do
        return false if @entries.size >= MAX_ENTRIES

        entry = {
          kind: kind, transaction_name: transaction_name, error_class: error_class, error_message: error_message,
          environment: configuration.environment.to_s, release: configuration.release,
          occurred_at: Time.now.utc.iso8601
        }
        # Strict privacy keeps the error's class, never its message.
        @entries << (configuration.strict_privacy ? StrictPrivacy.failure_event(entry) : entry)
      end
    end

    # Snapshots and resets the buffered entries, then delivers them as one batch. Same "a failed
    # delivery keeps every entry for the next attempt" contract as MetricBuffer#flush, with the
    # same two exceptions: a rejected batch, and one that failed FlushOutcome::MAX_FAILED_FLUSHES
    # flushes in a row, are dropped.
    def flush
      snapshot = nil

      @mutex.synchronize do
        return if @entries.empty?
        snapshot = @entries.dup
      end

      return unless @outcome.release?(client.deliver_failure_events(snapshot))

      # Exactly the entries just sent: anything recorded while the request was in flight sits after
      # them and stays for the next flush.
      @mutex.synchronize { @entries.shift(snapshot.size) }
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
          sleep configuration.failure_event_flush_interval
          flush
        rescue StandardError => e
          configuration.logger&.debug { "[ForgeOpsTracker] failure event flush thread error: #{e.class}: #{e.message}" }
        end
      end
  end
end
