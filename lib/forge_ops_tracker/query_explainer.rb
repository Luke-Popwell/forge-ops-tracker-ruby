require "json"
require "thread"
require "time"

module ForgeOpsTracker
  # Opt-in (configuration.explain_slow_queries, default false): asks PostgreSQL for the plan of a
  # slow SELECT and sends it, masked, to ForgeOps so a slow query shows why it was slow.
  #
  # What it never does, by design:
  # - EXPLAIN ANALYZE. Plain EXPLAIN only plans the statement, it never executes it.
  # - Touch the app's own connection or transaction. #consider only reads the notification payload
  #   and remembers the connection's pool; the EXPLAIN runs later, on this class's own background
  #   thread, on a connection it checks out of that pool itself, inside its own READ ONLY
  #   transaction with a 2 second statement_timeout, always rolled back.
  # - Explain anything but a single plain SELECT (see .explainable?).
  # - Raise. Every failure (a timeout, a permission error, an exhausted pool, a statement Postgres
  #   can't parse) is logged at debug and dropped.
  # - Send the original statement or its bind values anywhere. Both are held in memory only until
  #   the EXPLAIN runs; what goes out is the masked statement (exactly as sent on the span) and the
  #   plan with every string in it masked the same way, since plan conditions quote literals
  #   ("Filter": "(email = 'a@b.co'::text)").
  #
  # Rate limited per process: each distinct masked statement at most once per 10 minutes, and at
  # most 10 EXPLAINs per minute overall. Both are reserved when a query is accepted, not when its
  # EXPLAIN succeeds, so a statement whose EXPLAIN keeps failing still can't be retried more often.
  class QueryExplainer
    STATEMENT_INTERVAL = 600.0
    GLOBAL_WINDOW = 60.0
    GLOBAL_LIMIT = 10
    MAX_PLAN_BYTES = 64 * 1024
    STATEMENT_TIMEOUT = "2s".freeze
    CHECKOUT_TIMEOUT = 1
    QUEUE_SIZE = GLOBAL_LIMIT
    # Past this many remembered statements, the ones whose 10 minutes are up are forgotten, so an
    # app with endless distinct statements can't grow this without bound.
    MAX_REMEMBERED_STATEMENTS = 1_000

    # One pass, left to right, so a quote inside a comment or comment syntax inside a string can't
    # confuse the other: string literals (single-quoted and dollar-quoted) become "?", comments
    # become a space.
    LITERALS_AND_COMMENTS = %r{
      '(?:[^']|'')*(?:'|\z)
      | (?<tag>\$[A-Za-z_]*\$).*?(?:\k<tag>|\z)
      | /\*.*?(?:\*/|\z)
      | --[^\n]*
    }mx
    LOCKING_CLAUSE = /\bFOR\s+(?:NO\s+KEY\s+UPDATE|KEY\s+SHARE|UPDATE|SHARE)\b/i
    DATA_MODIFYING = /\b(?:INSERT|UPDATE|DELETE|MERGE)\b/i

    Job = Struct.new(:sql, :binds, :pool, :statement, :duration_ms, :captured_at, keyword_init: true)

    class << self
      # True on this class's own worker thread while it's running an EXPLAIN. Railtie's
      # sql.active_record subscriber skips those queries entirely, so the EXPLAIN (and its BEGIN,
      # SET LOCAL and ROLLBACK) never shows up as the app's own query timing, breadcrumbs or spans.
      def explaining?
        Thread.current[:forge_ops_tracker_explaining] == true
      end

      # Whether statement is a single plain SELECT: after dropping comments and string literals,
      # it starts with SELECT, has no ";" other than one trailing one, no locking clause (FOR
      # UPDATE, FOR SHARE, FOR NO KEY UPDATE, FOR KEY SHARE), and no INSERT, UPDATE, DELETE or
      # MERGE anywhere (so no data-modifying CTE either).
      def explainable?(statement)
        return false unless statement.is_a?(String)

        sql = statement.gsub(LITERALS_AND_COMMENTS) { |match| match.start_with?("'", "$") ? "?" : " " }.strip
        return false unless sql.match?(/\ASELECT\b/i)
        return false if sql.delete_suffix(";").include?(";")

        !sql.match?(LOCKING_CLAUSE) && !sql.match?(DATA_MODIFYING)
      end

      # Masks every String inside a parsed EXPLAIN (FORMAT JSON) result with SqlStatement, leaving
      # keys, numbers, booleans, arrays and the structure itself exactly as they were.
      def mask_plan(value)
        case value
        when Hash then value.transform_values { |inner| mask_plan(inner) }
        when Array then value.map { |inner| mask_plan(inner) }
        when String then SqlStatement.mask(value) || value
        else value
        end
      end
    end

    def initialize(configuration, client: Client.new(configuration), clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @configuration = configuration
      @client = client
      @clock = clock
      @queue = SizedQueue.new(QUEUE_SIZE)
      @mutex = Mutex.new
      @thread = nil
      @last_explained = {}
      @recent = []
    end

    # Called from the sql.active_record subscriber with that event's payload and duration. Cheap
    # checks first, so a fast query costs one comparison. Returns true only when an EXPLAIN was
    # queued; never raises.
    def consider(payload, duration_ms:)
      # Strict privacy sends no SQL at all, masked or not (sdks/STRICT_PRIVACY.md).
      return false unless configuration.explain_slow_queries && !configuration.strict_privacy
      return false unless duration_ms && duration_ms >= configuration.explain_threshold_ms.to_f

      connection = payload[:connection]
      system = PerformanceInstrumentation.db_system(connection)
      return false unless system == "postgresql"

      sql = payload[:sql]
      return false unless self.class.explainable?(sql)

      pool = connection.respond_to?(:pool) ? connection.pool : nil
      return false unless pool

      statement = SqlStatement.mask(sql, system: system)
      return false unless reserve(statement)

      enqueue(Job.new(
        sql: sql.dup, binds: bind_values(payload), pool: pool, statement: statement,
        duration_ms: duration_ms.to_f.round(1), captured_at: Time.now.utc.iso8601(3)
      ))
    rescue StandardError => e
      log { "EXPLAIN skipped: #{e.class}: #{e.message}" }
      false
    end

    # Runs one queued EXPLAIN and delivers its plan. Normally called on the worker thread; public so
    # a test can run a job synchronously. Never raises.
    def perform(job)
      plan = explain(job)
      return false unless plan

      masked_plan = self.class.mask_plan(plan)
      if JSON.generate(masked_plan).bytesize > MAX_PLAN_BYTES
        log { "EXPLAIN plan over #{MAX_PLAN_BYTES} bytes, dropped" }
        return false
      end

      result = client.deliver_query_plan(
        statement: job.statement, db_system: "postgresql", plan: masked_plan,
        duration_ms: job.duration_ms, environment: configuration.environment, captured_at: job.captured_at
      )
      DeliveryStatus.from(result) == DeliveryStatus::DELIVERED
    rescue StandardError => e
      log { "EXPLAIN failed: #{e.class}: #{e.message}" }
      false
    end

    private
      attr_reader :configuration, :client

      # Both rate limits at once, under one lock, so two threads finishing the same slow query
      # together still only explain it once.
      def reserve(statement)
        return false if statement.nil?

        @mutex.synchronize do
          now = @clock.call
          @recent.reject! { |at| now - at >= GLOBAL_WINDOW }
          return false if @recent.size >= GLOBAL_LIMIT

          last = @last_explained[statement]
          return false if last && now - last < STATEMENT_INTERVAL

          if @last_explained.size >= MAX_REMEMBERED_STATEMENTS
            @last_explained.reject! { |_, at| now - at >= STATEMENT_INTERVAL }
          end
          @last_explained[statement] = now
          @recent << now
          true
        end
      end

      # The values the app's own query was run with, already type cast for the database. Rails
      # passes these either as an Array or as a lambda that builds one.
      def bind_values(payload)
        binds = payload[:type_casted_binds]
        binds = binds.call if binds.respond_to?(:call)
        Array(binds).dup
      end

      def enqueue(job)
        ensure_worker_started
        @queue.push(job, true)
        true
      rescue ThreadError
        log { "EXPLAIN queue full, dropping" }
        false
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
        Thread.current[:forge_ops_tracker_explaining] = true
        loop do
          perform(@queue.pop)
        rescue StandardError => e
          log { "EXPLAIN thread error: #{e.class}: #{e.message}" }
        end
      end

      # The parsed plan (the JSON array Postgres returns), or nil. The connection is checked out
      # explicitly rather than borrowed with with_connection, so it's never one this thread (or
      # any other) already holds. Checked back in only once its transaction is rolled back; if
      # even the ROLLBACK fails, the connection is removed from the pool and closed instead, so a
      # connection in an unknown state is never handed to the app.
      def explain(job)
        connection = job.pool.checkout(CHECKOUT_TIMEOUT)
        begin
          connection.execute("BEGIN READ ONLY")
          connection.execute("SET LOCAL statement_timeout = '#{STATEMENT_TIMEOUT}'")
          result = connection.exec_query("EXPLAIN (FORMAT JSON) #{job.sql}", "EXPLAIN", job.binds)
          value = result.rows.first&.first
          value.is_a?(String) ? JSON.parse(value) : value
        ensure
          release(job.pool, connection, rollback(connection))
        end
      end

      def rollback(connection)
        connection.execute("ROLLBACK")
        true
      rescue StandardError => e
        log { "EXPLAIN rollback failed: #{e.class}: #{e.message}" }
        false
      end

      def release(pool, connection, healthy)
        if healthy
          pool.checkin(connection)
        else
          pool.remove(connection)
          connection.disconnect!
        end
      rescue StandardError => e
        log { "EXPLAIN connection release failed: #{e.class}: #{e.message}" }
      end

      def log
        configuration.logger&.debug { "[ForgeOpsTracker] #{yield}" }
      end
  end
end
