require "rails/railtie"

module ForgeOpsTracker
  class Railtie < ::Rails::Railtie
    # Shared across every performance-timing subscription/integration below (controller, query,
    # job, raw Sidekiq, outbound Net::HTTP): one flusher, one background thread, one set of
    # buckets, since PerformanceFlusher already buckets on [transaction_name, kind] and safely
    # handles concurrent calls from several sources at once. Exposed as a class method, not a
    # local variable inside one initializer, specifically so the Sidekiq/Net::HTTP integrations
    # (each guarded by their own separate initializer, since each only loads if its own optional
    # library is present) can record into the exact same instance rather than each starting a
    # redundant flusher/thread of their own.
    class << self
      def performance_flusher
        @performance_flusher ||= ForgeOpsTracker::PerformanceFlusher.new(ForgeOpsTracker.configuration)
      end

      # Same reasoning as performance_flusher above, exposed the identical way: shared across the
      # two failure-detecting call sites below (the perform.active_job subscription, Net::HTTP's
      # own Timing#request), one buffer/thread rather than each starting a redundant one.
      def failure_event_buffer
        @failure_event_buffer ||= ForgeOpsTracker::FailureEventBuffer.new(ForgeOpsTracker.configuration)
      end

      # Same reasoning again, exposed the identical way: shared across every call site that might
      # finish a captured trace (Middleware::SpanTracing today; nothing else yet, but the same
      # "one instance, not one per call site" reasoning applies regardless).
      def span_queue
        @span_queue ||= ForgeOpsTracker::SpanQueue.new(ForgeOpsTracker.configuration)
      end

      # One per process, so its rate limits (see QueryExplainer) are per process too.
      def query_explainer
        @query_explainer ||= ForgeOpsTracker::QueryExplainer.new(ForgeOpsTracker.configuration)
      end
    end

    initializer "forge_ops_tracker.subscribe_error_reporter" do |app|
      configuration = ForgeOpsTracker.configuration
      configuration.app_root ||= app.root.to_s
      # FORGE_OPS_ENVIRONMENT wins when set, so a staging box running RAILS_ENV=production can
      # still report as staging; otherwise Rails.env, so development and test stay quiet.
      forge_ops_environment = ENV["FORGE_OPS_ENVIRONMENT"].to_s.strip
      configuration.environment = forge_ops_environment.empty? ? Rails.env.to_s : forge_ops_environment
      configuration.logger ||= Rails.logger

      Rails.error.subscribe(ForgeOpsTracker.error_subscriber)
    end

    # After every config/initializers file has run, so the DSN and environment are final: one
    # warning at boot when a DSN is set but this environment doesn't send (development, say).
    config.after_initialize do
      ForgeOpsTracker.warn_if_environment_disabled
    end

    initializer "forge_ops_tracker.track_sessions" do |app|
      app.middleware.use ForgeOpsTracker::Middleware::SessionTracking, configuration: ForgeOpsTracker.configuration
    end

    # Warden::Manager (mounted automatically by Devise, or directly by any other Warden-based
    # auth setup) sets env["warden"] itself; this only ever reads it, so it works regardless of
    # exactly where in the middleware stack this ends up relative to Warden::Manager, as long as
    # that key exists in env by the time this middleware's own #call runs, which is true for any
    # Warden-based auth setup: it mounts its own middleware once, for the whole app, long before
    # any individual request begins.
    initializer "forge_ops_tracker.track_current_user" do |app|
      app.middleware.use ForgeOpsTracker::Middleware::UserContext, configuration: ForgeOpsTracker.configuration
    end

    # Gives every request its own fresh BreadcrumbBuffer to accumulate into (see
    # ForgeOpsTracker::Middleware::BreadcrumbContext for why this has to be a middleware, the same
    # "Rails.error.subscribe never receives the Rack env" reasoning UserContext's own comment
    # gives): must run before the sql.active_record/process_action.action_controller subscriptions
    # below can have anywhere to record into, but Rack middleware ordering guarantees that already,
    # since this wraps app.call(env), and those notifications only ever fire from *inside* that
    # call.
    initializer "forge_ops_tracker.track_breadcrumbs" do |app|
      app.middleware.use ForgeOpsTracker::Middleware::BreadcrumbContext, configuration: ForgeOpsTracker.configuration
    end

    # Same "must run before the notifications below have anywhere to record into" reasoning as
    # track_breadcrumbs's own comment just above, for the exact same structural reason (Rack
    # middleware always wraps the actual controller dispatch those notifications fire from inside
    # of, regardless of this initializer's own position relative to track_breadcrumbs/
    # track_current_user/track_sessions).
    initializer "forge_ops_tracker.track_tracing" do |app|
      app.middleware.use ForgeOpsTracker::Middleware::SpanTracing, configuration: ForgeOpsTracker.configuration
    end

    # Must stay the last app.middleware.use in this file, so RequestContext is the innermost of
    # this gem's middlewares: its rescue is what copies the user, the breadcrumb trail, and the
    # trace id/endpoint onto an unhandled exception before any of the middlewares above clear their
    # thread-locals in their own ensure blocks, and ActionDispatch::Executor (which reports that
    # exception in Rails 8.1) sits outside all of them. See that middleware's own comment.
    # Initializers within one Railtie run in the order they're defined, and app.middleware.use
    # appends, so being defined after track_tracing is what makes it innermost.
    #
    # start_processing.action_controller fires as the controller begins handling the request, before
    # the action itself runs (unlike process_action.action_controller below, which only fires once
    # it has finished), so a handled error reported from inside the action (Rails.error.handle/
    # record) already knows which transaction and endpoint it happened in. Its payload carries
    # :controller/:action/:method, plus :request from Rails 7.1 on (see
    # PerformanceInstrumentation.controller_endpoint for what each is used for).
    initializer "forge_ops_tracker.request_context" do |app|
      configuration = ForgeOpsTracker.configuration
      # report_exceptions: false because Rails.error already reports an unhandled request error.
      app.middleware.use ForgeOpsTracker::Middleware::RequestContext, configuration: configuration, report_exceptions: false

      ActiveSupport::Notifications.subscribe("start_processing.action_controller") do |*args|
        next unless configuration.enabled?

        ForgeOpsTracker::Middleware::RequestContext.current&.controller_started(args.last)
      end
    end

    # Rails already fires "process_action.action_controller" after every request with the
    # controller/action and how long it took (event.duration, in ms) built in, so unlike session
    # tracking above (which needed a Rack middleware because there's no single existing hook for
    # "a request finished"), this needs no middleware of its own at all, just a subscriber.
    # Guarded the same way the error subscriber and session-tracking middleware both are: on by
    # default, off entirely if track_performance is turned off or the gem itself isn't enabled
    # (no DSN configured, or the current environment isn't in enabled_environments).
    #
    # sql.active_record/perform.active_job are subscribed here too, not in their own separate
    # initializers: all three (plus Sidekiq/Net::HTTP below) are genuinely the same concern
    # (automatic performance timing), sharing the one performance_flusher above; see
    # PerformanceInstrumentation for the actual transaction_name/skip decisions each one makes,
    # kept out of these blocks specifically so that decision logic is unit-testable without a real
    # Rails/ActiveJob boot (this gem's own test suite doesn't require Rails at all; see that
    # file's own comment).
    #
    # The same two subscriptions also record a breadcrumb, gated on track_breadcrumbs
    # independently of track_performance: an app could want the trail without the timing data, or
    # vice versa, and each already has to check its own flag regardless, so there's no real cost
    # to keeping them independent rather than tying breadcrumbs to whether performance monitoring
    # happens to be on.
    #
    # Every event.time below is wrapped in Time.at(...) before being handed to SpanBuffer#record or
    # job_queue_wait_ms, both of which need a real Time. ActiveSupport::Notifications::Event#time
    # returns a plain Float (seconds since the epoch) on the Rails version this gem currently
    # targets, not a Time; Time.at(...) also passes a real Time straight through unchanged, so this
    # stays correct if a future Rails version goes back to returning one.
    initializer "forge_ops_tracker.track_performance" do
      configuration = ForgeOpsTracker.configuration
      flusher = Railtie.performance_flusher

      ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
        next unless configuration.enabled?

        event = ActiveSupport::Notifications::Event.new(*args)
        transaction_name = PerformanceInstrumentation.controller_transaction_name(event.payload)

        if configuration.track_performance
          flusher.record(transaction_name: transaction_name, duration_ms: event.duration, kind: "controller")
        end

        if configuration.track_breadcrumbs
          status = event.payload[:status]
          ForgeOpsTracker.add_breadcrumb(
            "#{event.payload[:method]} #{transaction_name}",
            category: "controller",
            level: status && status >= 500 ? "error" : "info",
            data: { status: status, path: event.payload[:path] }.compact
          )
        end

        # Records this request's own root span, not gated on track_performance/track_breadcrumbs
        # above (its own independent configuration.track_tracing flag instead, the same "several
        # genuinely independent mechanisms recorded from the same instrumentation point" pattern
        # this exact call site already established for breadcrumbs): this is the one call in the
        # whole gem that ever passes root: true, since process_action.action_controller is the only
        # instrumentation point that wraps a genuinely whole request. See SpanBuffer#record's own
        # comment for why root: true takes its parent_span_id from the incoming traceparent header
        # (nil when there wasn't one) rather than reading it off the (already-popped-by-now) stack.
        if configuration.track_tracing && (buffer = Thread.current[:forge_ops_tracker_spans])
          buffer.pop
          buffer.record(
            span_id: buffer.root_span_id, name: transaction_name, kind: "controller",
            started_at: Time.at(event.time), duration_ms: event.duration, root: true
          )
        end
      end

      ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        # QueryExplainer's own EXPLAIN (and its BEGIN/SET LOCAL/ROLLBACK), on its own thread: not
        # the app's query, so never timed, traced or explained itself.
        next if QueryExplainer.explaining?
        next unless configuration.enabled?

        event = ActiveSupport::Notifications::Event.new(*args)
        transaction_name = PerformanceInstrumentation.query_transaction_name(event.payload)
        next if transaction_name.nil? # SCHEMA/cached, see PerformanceInstrumentation's own comment

        if configuration.track_performance
          flusher.record(transaction_name: transaction_name, duration_ms: event.duration, kind: "query")
        end

        if configuration.track_breadcrumbs
          ForgeOpsTracker.add_breadcrumb(transaction_name, category: "query", data: { duration_ms: event.duration.round(1) })
        end

        # A leaf span, parented onto whatever's currently open (the controller root, or a
        # manually-wrapped ForgeOpsTracker.span block around it): a query has no children of its
        # own to nest anything under, so unlike the controller root above, this never touches the
        # stack itself, just records against whatever's already on top of it. Carries the masked
        # SQL and the database system (see PerformanceInstrumentation.database_span_data).
        if configuration.track_tracing && (buffer = Thread.current[:forge_ops_tracker_spans])
          buffer.record(
            span_id: SecureRandom.hex(8), name: transaction_name, kind: "database",
            started_at: Time.at(event.time), duration_ms: event.duration,
            data: PerformanceInstrumentation.database_span_data(event.payload)
          )
        end

        # Opt-in, PostgreSQL only; a no-op unless config.explain_slow_queries is on. Only reads the
        # payload here; the EXPLAIN itself runs later on QueryExplainer's own thread and connection.
        Railtie.query_explainer.consider(event.payload, duration_ms: event.duration) if configuration.explain_slow_queries
      end

      ActiveSupport::Notifications.subscribe("perform.active_job") do |*args|
        # Permissive enough for either concern below to run on its own: track_performance off but
        # track_failures on (or vice versa) still needs this subscription to fire at all.
        next unless (configuration.track_performance || configuration.track_failures) && configuration.enabled?

        event = ActiveSupport::Notifications::Event.new(*args)

        if configuration.track_performance
          transaction_name = PerformanceInstrumentation.job_transaction_name(event.payload)
          flusher.record(transaction_name: transaction_name, duration_ms: event.duration, kind: "job")

          # A second, independent sample from the same notification: how long this job actually
          # waited in its queue before this perform even started, not how long perform itself took
          # (the "job" kind above). Grouped by queue name, not job class, since queue-level backlog
          # is the actionable unit here (a slow queue affects every job class routed through it),
          # the same reason Solid Queue's own StatsReporter already reports queue_depth per queue
          # name rather than per job class. See PerformanceInstrumentation.job_queue_wait_ms's own
          # comment for why this is nil, and skipped, for a job that was never actually enqueued.
          wait_ms = PerformanceInstrumentation.job_queue_wait_ms(event.payload, at: Time.at(event.time))
          if wait_ms
            flusher.record(transaction_name: event.payload[:job].queue_name, duration_ms: wait_ms, kind: "job_latency")
          end
        end

        # Independent of track_performance above, same reasoning breadcrumbs already established
        # at this exact call site: a job whose perform raised, via
        # PerformanceInstrumentation.job_failure_details' own use of ActiveSupport::Notifications'
        # automatic payload[:exception_object] (see that method's own comment).
        if configuration.track_failures
          failure = PerformanceInstrumentation.job_failure_details(event.payload)
          if failure
            Railtie.failure_event_buffer.record(
              kind: "job", transaction_name: PerformanceInstrumentation.job_transaction_name(event.payload),
              error_class: failure[:error_class], error_message: failure[:error_message]
            )
          end
        end
      end
    end

    # Raw (non-ActiveJob) Sidekiq::Worker job timing, plus Sidekiq's own queue-depth/processed/
    # failed/etc. gauges: a separate initializer, since unlike ActiveRecord/ActionController
    # (always present in any Rails app this gem's own gemspec already implies), Sidekiq is
    # genuinely optional and isn't a declared dependency of this gem at all.
    initializer "forge_ops_tracker.track_sidekiq" do
      next unless defined?(::Sidekiq)

      require "forge_ops_tracker/integrations/sidekiq"

      configuration = ForgeOpsTracker.configuration
      ::Sidekiq.configure_server do |config|
        config.server_middleware do |chain|
          # No extra args to chain.add: Sidekiq calls Middleware.new(*args) itself for every job,
          # splatting whatever was passed here; the middleware's own keyword-argument defaults
          # (ForgeOpsTracker.configuration, Railtie.performance_flusher) already resolve correctly
          # when called with none, and passing a keyword hash through *args here is genuinely
          # ambiguous (Sidekiq's own chain.add doc example passes a literal positional Hash, not
          # keyword syntax, for exactly this reason).
          chain.add ForgeOpsTracker::Integrations::Sidekiq::Middleware
        end
      end

      ForgeOpsTracker::Integrations::Sidekiq::StatsReporter.start(configuration: configuration)
    end

    initializer "forge_ops_tracker.track_solid_queue" do
      next unless defined?(::SolidQueue)

      require "forge_ops_tracker/integrations/solid_queue"
      ForgeOpsTracker::Integrations::SolidQueue::StatsReporter.start(configuration: ForgeOpsTracker.configuration)
    end

    initializer "forge_ops_tracker.track_puma" do
      next unless defined?(::Puma)

      require "forge_ops_tracker/integrations/puma"
      ForgeOpsTracker::Integrations::Puma::StatsReporter.start(configuration: ForgeOpsTracker.configuration)
    end

    # Same defined? guard as track_sidekiq/track_solid_queue/track_puma above, not
    # track_net_http's unconditional one: ActiveRecord is neither Ruby stdlib nor a declared
    # dependency of this gem itself (this gem has none at all beyond Rails::Railtie being
    # defined; see the gemspec's own comment on why even Sidekiq/Puma are dev-only dependencies),
    # so an API-only Rails app with ActiveRecord genuinely removed is a real, if uncommon, case to
    # guard against rather than assume away.
    initializer "forge_ops_tracker.track_active_record_pool" do
      next unless defined?(::ActiveRecord::Base)

      require "forge_ops_tracker/integrations/active_record_pool"
      ForgeOpsTracker::Integrations::ActiveRecordPool::StatsReporter.start(configuration: ForgeOpsTracker.configuration)
    end

    # Net::HTTP is always present (Ruby's own standard library), so this always prepends; the
    # actual on/off decision happens at call time inside Timing#request itself (checking
    # configuration.track_performance/enabled? the same way the subscriptions above do), so
    # toggling that flag after boot still takes effect immediately, the same as every other
    # automatic instrumentation point in this gem.
    initializer "forge_ops_tracker.track_net_http" do
      require "forge_ops_tracker/integrations/net_http"
      Net::HTTP.prepend(ForgeOpsTracker::Integrations::NetHTTP::Timing)
    end

    # defined?(::RedisClient) guarded, the same way track_sidekiq/track_solid_queue/track_puma
    # above are: RedisClient is neither Ruby stdlib nor a declared dependency of this gem (see the
    # gemspec's own comment on why even Sidekiq/Puma are dev-only dependencies), so a host app with
    # no Redis at all is a real case to guard against, not assume away. Runs after Rails itself has
    # finished booting (config.after_initialize, not a plain initializer like track_net_http
    # above): unlike Net::HTTP (Ruby stdlib, always loaded), whether RedisClient is defined yet at
    # plain initializer time depends on load order relative to whatever gem requires it (redis,
    # sidekiq, ActiveJob's redis queue adapter, ...), which this gem has no control over; deferring
    # the defined? check to after every railtie (including this app's own dependencies) has
    # finished initializing avoids a load-order-dependent false negative.
    # After initialization, not in a plain initializer, so the app's own
    # config/initializers/forge_ops_tracker.rb has already run (detect_changes/track_env_var_names
    # and the DSN are final) and Active Record is configured enough to report the migration
    # version. ChangeSnapshot does the actual work on its own thread, so boot never waits on it.
    config.after_initialize do
      ForgeOpsTracker::ChangeSnapshot.start(ForgeOpsTracker.configuration)
    end

    config.after_initialize do
      next unless defined?(::RedisClient)

      require "forge_ops_tracker/integrations/redis_client"
      ::RedisClient.prepend(ForgeOpsTracker::Integrations::RedisClientTiming)
    end
  end
end
