require "thread"

module ForgeOpsTracker
  # Counts requests and crashes in-process (see Middleware::SessionTracking) and periodically
  # flushes the totals as one small aggregate report, rather than one network call per request.
  # Same "lazily start a background thread on first use, not at load time" pattern DeliveryQueue
  # already uses, so each forked Puma/Passenger worker gets its own fresh thread instead of
  # inheriting a dead one across fork; here it's triggered by a sleep-loop timer instead of a
  # queue push, since there's no per-event signal to wait on, just a clock.
  class SessionFlusher
    def initialize(configuration, client: Client.new(configuration))
      @configuration = configuration
      @client = client
      @mutex = Mutex.new
      @sessions_count = 0
      @crashed_sessions_count = 0
      @period_started_at = Time.now.utc
      @thread = nil
      @outcome = FlushOutcome.new(configuration, "session counts")

      # Flushes whatever's already tallied on a normal process exit, so the last partial window
      # (anything shorter than a full session_flush_interval) isn't silently dropped.
      at_exit { flush }
    end

    def record_session(crashed:)
      ensure_worker_started

      @mutex.synchronize do
        @sessions_count += 1
        @crashed_sessions_count += 1 if crashed
      end
    end

    # Snapshots and resets the in-process counters, then delivers them. A failed delivery keeps
    # the counts where they are rather than resetting, so the next flush's window just grows
    # instead of losing what was already tallied; there's no other copy of this data anywhere.
    # Counts the server rejected, or that failed FlushOutcome::MAX_FAILED_FLUSHES flushes in a
    # row, are reset all the same: sending them again could never succeed.
    def flush
      snapshot = nil

      @mutex.synchronize do
        return if @sessions_count.zero?

        snapshot = {
          release: configuration.release,
          environment: configuration.environment.to_s,
          period_started_at: @period_started_at.iso8601,
          period_ended_at: Time.now.utc.iso8601,
          sessions_count: @sessions_count,
          crashed_sessions_count: @crashed_sessions_count
        }
      end

      return unless snapshot && @outcome.release?(client.deliver_session_checkin(snapshot))

      @mutex.synchronize do
        @sessions_count = 0
        @crashed_sessions_count = 0
        @period_started_at = Time.now.utc
      end
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
          sleep configuration.session_flush_interval
          flush
        rescue StandardError => e
          configuration.logger&.debug { "[ForgeOpsTracker] session flush thread error: #{e.class}: #{e.message}" }
        end
      end
  end
end
