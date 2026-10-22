require "thread"

module ForgeOpsTracker
  # Times every request/job/query/outbound call in-process, bucketed by [transaction_name, kind]
  # (see Railtie's several ActiveSupport::Notifications subscriptions, each a different kind), and
  # periodically flushes each distinct bucket as one small aggregate report, rather than one
  # network call per event. One shared flusher for every kind, not one per kind: the aggregation
  # shape (count + duration sum + max over a period) is identical regardless of what's actually
  # being timed. Same "lazily start a background thread on first use, not at load time" pattern
  # SessionFlusher already uses, so each forked Puma/Passenger worker gets its own fresh thread
  # instead of inheriting a dead one across fork.
  class PerformanceFlusher
    def initialize(configuration, client: Client.new(configuration))
      @configuration = configuration
      @client = client
      @mutex = Mutex.new
      @buckets = {}
      @period_started_at = Time.now.utc
      @thread = nil
      @outcome = FlushOutcome.new(configuration, "performance samples")

      # Flushes whatever's already tallied on a normal process exit, so the last partial window
      # (anything shorter than a full performance_flush_interval) isn't silently dropped; same
      # reasoning SessionFlusher's own at_exit hook documents.
      at_exit { flush }
    end

    # kind ("controller"/"job"/"query"/"http", see Railtie's own subscriptions) is part of the
    # bucket key alongside transaction_name, not folded into transaction_name itself: a job and a
    # controller action (or, less likely but still real, a query and a job) can share a name
    # without colliding into the same bucket.
    def record(transaction_name:, duration_ms:, kind: "controller")
      ensure_worker_started
      # Under strict privacy a raw-path name keeps only its first segment; a route or
      # Controller#action is kept.
      transaction_name = StrictPrivacy.transaction_name(transaction_name) if configuration.strict_privacy

      @mutex.synchronize do
        bucket = (@buckets[[ transaction_name, kind ]] ||= { count: 0, duration_sum_ms: 0.0, max_duration_ms: 0.0, histogram: Hash.new(0) })
        bucket[:count] += 1
        bucket[:duration_sum_ms] += duration_ms
        bucket[:max_duration_ms] = duration_ms if duration_ms > bucket[:max_duration_ms]
        # The distribution count/sum/max above can't reconstruct: see HistogramBucketer's own
        # comment for why an approximate percentile from these bucket counts, not a true one from
        # the raw values this gem deliberately never stores, is what the server computes from this.
        bucket[:histogram][HistogramBucketer.bucket_for(duration_ms)] += 1
      end
    end

    # Snapshots and resets the in-process buckets, then delivers them as one batch. A failed
    # delivery keeps every bucket where it is rather than resetting, so the next flush's window
    # just grows instead of losing what was already tallied; same reasoning SessionFlusher#flush
    # already documents, and the same reason PerformanceSamplesController accepts a batch rather
    # than a single row: a failed flush shouldn't have to re-deliver by transaction one at a time.
    # That only holds for a delivery that failed for now, and only FlushOutcome::MAX_FAILED_FLUSHES
    # times in a row: a batch the server rejected, or one that keeps failing, is removed exactly
    # the way a delivered one is, since re-sending it could never succeed.
    #
    # Only exactly what this snapshot delivered is removed afterward (subtracted from whatever is in
    # each bucket by then), never the whole hash reset: #record can run on another thread while the
    # HTTP request is in flight, so a call for a bucket already in the snapshot, or a brand-new one,
    # can land between the snapshot and delivery succeeding, and resetting afterward would silently
    # discard it. The SDKs ported from this gem all fixed that; this class had the same bug.
    # max_duration_ms is left as whatever is currently on the bucket, sent or not: a max can't be
    # "subtracted" back out, and leaving it never overstates the next period's own max.
    def flush
      snapshot = nil
      sent = nil
      period_started_at = nil
      period_ended_at = nil

      @mutex.synchronize do
        return if @buckets.empty?

        period_started_at = @period_started_at
        period_ended_at = Time.now.utc
        sent = @buckets.transform_values { |bucket| { count: bucket[:count], duration_sum_ms: bucket[:duration_sum_ms], histogram: bucket[:histogram].dup } }
        snapshot = @buckets.map do |(transaction_name, kind), bucket|
          {
            transaction_name: transaction_name,
            kind: kind,
            environment: configuration.environment.to_s,
            release: configuration.release,
            period_started_at: period_started_at.iso8601,
            period_ended_at: period_ended_at.iso8601,
            request_count: bucket[:count],
            duration_sum_ms: bucket[:duration_sum_ms],
            max_duration_ms: bucket[:max_duration_ms],
            histogram: bucket[:histogram].dup
          }
        end
      end

      return unless snapshot && @outcome.release?(client.deliver_performance_samples(snapshot))

      @mutex.synchronize do
        sent.each do |key, delivered|
          current = @buckets[key]
          next unless current

          current[:count] -= delivered[:count]
          current[:duration_sum_ms] = [ current[:duration_sum_ms] - delivered[:duration_sum_ms], 0.0 ].max
          delivered[:histogram].each do |bucket_key, count|
            current[:histogram][bucket_key] -= count
            current[:histogram].delete(bucket_key) if current[:histogram][bucket_key] <= 0
          end
          @buckets.delete(key) if current[:count] <= 0
        end
        @period_started_at = period_ended_at
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
          sleep configuration.performance_flush_interval
          flush
        rescue StandardError => e
          configuration.logger&.debug { "[ForgeOpsTracker] performance flush thread error: #{e.class}: #{e.message}" }
        end
      end
  end
end
