module ForgeOpsTracker
  # The actual "what do we call this, and should we even record it" decisions Railtie's
  # ActiveSupport::Notifications subscriptions make, pulled out into plain module-function methods
  # rather than left inline in each subscribe block. Railtie itself only ever loads when
  # Rails::Railtie is already defined (see lib/forge_ops_tracker.rb's own final line), so nothing
  # in that file can be exercised by this gem's own test suite without adding Rails itself as a
  # development dependency just to fire a notification event by hand; every method here takes a
  # plain payload Hash instead of a real ActiveSupport::Notifications::Event, so the decision logic
  # itself (the SCHEMA/cached skip, the ActiveJob-wrapper dedup) is fully unit-testable with no
  # Rails/Sidekiq/ActiveJob dependency at all. Railtie's own subscribe blocks stay thin, calling
  # straight into these.
  module PerformanceInstrumentation
    module_function

    def controller_transaction_name(payload)
      "#{payload[:controller]}##{payload[:action]}"
    end

    # A human-readable route for an error event's `endpoint` field, "<HTTP method> <route pattern>"
    # ("POST /checkout", "GET /orders/:id"): the route as it was declared in config/routes.rb, never
    # the literal request path, so it stays low-cardinality and never carries an id or a token, the
    # same reasoning every transaction_name in this system already follows. payload[:request] is
    # only present in Rails 7.1+, the same release that added
    # ActionDispatch::Request#route_uri_pattern; on anything older (or a request with no matched
    # route pattern at all) this falls back to the controller/action name instead
    # ("GET CheckoutsController#create"), still meaningful, just less familiar-looking than a URL.
    def controller_endpoint(payload)
      target = route_pattern(payload[:request]) || controller_transaction_name(payload)
      method = payload[:method]
      method.nil? || method.to_s.empty? ? target : "#{method} #{target}"
    end

    # Rails appends an optional "(.:format)" segment to nearly every route pattern it generates;
    # it's noise in a label a person reads, so it's dropped. Defensive about everything else, since
    # this runs inside a notification subscriber on every single request: a request object without
    # the method, a nil/empty pattern, or the method itself raising all just mean "no pattern," and
    # the caller falls back.
    def route_pattern(request)
      return nil unless request.respond_to?(:route_uri_pattern)

      pattern = request.route_uri_pattern
      return nil if pattern.nil? || pattern.to_s.empty?

      pattern = pattern.to_s.delete_suffix("(.:format)")
      pattern.empty? ? "/" : pattern
    rescue StandardError
      nil
    end

    # nil means "don't record this one": Rails' own sql.active_record fires for two kinds of
    # noise that would drown out real query timing otherwise. "SCHEMA" is Rails' own internal
    # introspection (column lookups, etc.), never something a customer's own code triggered;
    # payload[:cached] is a genuinely instant hash lookup off Rails' own query cache, not a real
    # round trip to the database, so timing it would understate every cached query's own real
    # cost the next time it isn't cached.
    #
    # payload[:name] (Rails' own auto-generated label, e.g. "User Load", "Order Create"), not
    # payload[:sql] (the literal query text): a customer's own query text could carry a literal
    # value in some edge cases despite ActiveRecord's own parameterization, and even where it
    # doesn't, raw SQL text is far higher cardinality than this system's transaction_name is
    # designed for everywhere else. Falls back to the literal string "SQL" for the rare query
    # with no name at all, rather than skipping it outright.
    def query_transaction_name(payload)
      return nil if payload[:name] == "SCHEMA" || payload[:cached]

      # A plain nil-or-empty check, not ActiveSupport's #presence: this module is unit-tested
      # without Rails/ActiveSupport loaded at all (see this file's own top comment), so it can't
      # rely on a method ActiveSupport adds to String/NilClass.
      name = payload[:name]
      name.nil? || name.empty? ? "SQL" : name
    end

    # Active Record's adapter names, as ForgeOps' "db.system" values. Anything not listed here is
    # sent as its own adapter name, lowercased.
    DB_SYSTEMS = {
      "postgresql" => "postgresql", "postgis" => "postgresql",
      "mysql" => "mysql", "mysql2" => "mysql", "trilogy" => "mysql",
      "sqlite" => "sqlite", "sqlite3" => "sqlite",
      "sqlserver" => "mssql",
      "oracle" => "oracle", "oracleenhanced" => "oracle"
    }.freeze

    # The "data" a database span carries: the query's SQL, masked by SqlStatement (every string
    # and number literal becomes "?", so no value the app queried with is ever sent), and which
    # database it ran on, from the connection's adapter. Either is left out when it isn't known.
    def database_span_data(payload)
      system = db_system(payload[:connection])
      {
        "db.statement" => SqlStatement.mask(payload[:sql].to_s, system: system),
        "db.system" => system
      }.compact
    end

    # payload[:connection] is the adapter instance the query ran on (Rails 6.0 and later).
    def db_system(connection)
      return nil unless connection.respond_to?(:adapter_name)

      name = connection.adapter_name.to_s.downcase
      return nil if name.empty?

      DB_SYSTEMS.fetch(name, name)
    rescue StandardError
      nil
    end

    def job_transaction_name(payload)
      payload[:job].class.name
    end

    # nil means "don't record this one": a job run via perform_now (directly, or as ActiveJob's
    # own synchronous fallback) never goes through enqueue/serialize at all, so its enqueued_at
    # stays nil (confirmed directly against ActiveJob::Core/Enqueuing's own source, not assumed),
    # and a job that was never actually enqueued has no queue wait time to report; a bogus
    # zero-or-negative duration would be actively misleading in a "how backed up is this queue"
    # view, not just uninteresting.
    #
    # Takes at: explicitly (the perform.active_job event's own start time) rather than calling
    # Time.now itself: keeps this unit-testable with a plain fixed Time, the same reason every
    # other method in this module takes a plain payload Hash instead of reaching for real
    # Rails/ActiveJob state (see this file's own top comment).
    def job_queue_wait_ms(payload, at:)
      enqueued_at = payload[:job].enqueued_at
      return nil unless enqueued_at

      (at - enqueued_at) * 1000.0
    end

    # nil means "this job didn't fail": ActiveSupport::Notifications.instrument (which
    # perform.active_job already goes through) automatically populates payload[:exception_object]
    # with whatever the instrumented block raised, confirmed directly against the installed
    # activesupport gem's own documented behavior, not assumed; a job that completed normally
    # never gets this key at all. Returns the raised exception's own class name/message, not the
    # exception object itself, matching every other detail this module already extracts as plain
    # strings rather than passing real framework objects back out to Railtie.
    def job_failure_details(payload)
      exception = payload[:exception_object]
      return nil unless exception

      { error_class: exception.class.name, error_message: exception.message.to_s }
    end

    # True for a job dispatched through ActiveJob but actually run on Sidekiq: Sidekiq's own
    # server middleware chain wraps every job it runs, ActiveJob-dispatched or not, so without
    # this check a job on the Sidekiq/ActiveJob combination would be recorded twice: once here
    # (kind: "job", via the raw Sidekiq middleware) and once already by the perform.active_job
    # subscription that already covers every ActiveJob job regardless of which queue backend
    # actually runs it (Solid Queue, Sidekiq, or anything else). The class name itself is
    # ActiveJob's own, not this gem's: confirmed directly against how ActiveJob wraps a job for
    # Sidekiq, not assumed from either project's docs alone.
    def sidekiq_worker_is_active_job_wrapper?(worker)
      return false unless defined?(::ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper)

      worker.is_a?(::ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper)
    end
  end
end
