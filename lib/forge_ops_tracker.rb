require "securerandom"
require "forge_ops_tracker/version"
require "forge_ops_tracker/configuration"
require "forge_ops_tracker/pii_scrubber"
require "forge_ops_tracker/sql_statement"
require "forge_ops_tracker/strict_privacy"
require "forge_ops_tracker/event_builder"
require "forge_ops_tracker/delivery_status"
require "forge_ops_tracker/client"
require "forge_ops_tracker/delivery_queue"
require "forge_ops_tracker/change"
require "forge_ops_tracker/change_snapshot"
require "forge_ops_tracker/error_subscriber"
require "forge_ops_tracker/session_flusher"
require "forge_ops_tracker/histogram_bucketer"
require "forge_ops_tracker/performance_flusher"
require "forge_ops_tracker/performance_instrumentation"
require "forge_ops_tracker/metric_buffer"
require "forge_ops_tracker/infrastructure_metric_buffer"
require "forge_ops_tracker/failure_event_buffer"
require "forge_ops_tracker/periodic_poller"
require "forge_ops_tracker/breadcrumb_buffer"
require "forge_ops_tracker/span_buffer"
require "forge_ops_tracker/span_queue"
require "forge_ops_tracker/query_explainer"
require "forge_ops_tracker/trace_parent"
require "forge_ops_tracker/request_state"
require "forge_ops_tracker/middleware/session_tracking"
require "forge_ops_tracker/middleware/user_context"
require "forge_ops_tracker/middleware/breadcrumb_context"
require "forge_ops_tracker/middleware/span_tracing"
require "forge_ops_tracker/middleware/request_context"

module ForgeOpsTracker
  ENVIRONMENT_WARNING_LOCK = Mutex.new

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    # Outside Rails this is also where the startup ChangeSnapshot goes out, since there's no
    # Railtie to send it once the app has booted; under Rails the Railtie sends it instead, after
    # initialization, when Active Record can report the migration version. The same goes for the
    # one-time "Not sending" warning (see warn_if_environment_disabled).
    def configure
      yield configuration
      return if defined?(::Rails::Railtie)

      warn_if_environment_disabled
      ChangeSnapshot.start(configuration)
    end

    # Reports an exception you've already rescued, e.g. from a Sinatra error handler, a plain Rack
    # app, a script, or a background worker that isn't wired through Rails.error. Goes through the
    # same ErrorSubscriber Rails.error reports into, so it carries the current request's user,
    # breadcrumbs and trace the same way, and is a no-op when the gem isn't enabled. Under Rails,
    # Rails.error.report/handle/record do the same thing. Never raises.
    def capture_exception(error, context: {})
      warn_if_environment_disabled unless configuration.enabled?
      error_subscriber.report(error, handled: true, context: context || {}, source: "application")
    end

    # The one ErrorSubscriber this process reports through: the Railtie subscribes it to
    # Rails.error, and capture_exception calls it directly, so both share one delivery queue.
    def error_subscriber
      @error_subscriber ||= ErrorSubscriber.new(configuration)
    end

    # Logs one warning per process when a DSN is set but the environment isn't in
    # enabled_environments, so a process that would send nothing says so instead of staying
    # silent. Goes to configuration.logger (Rails.logger under Rails), or $stderr when there isn't
    # one. Never logs without a DSN. Returns whether it logged.
    def warn_if_environment_disabled
      message = configuration.disabled_environment_warning
      return false unless message

      ENVIRONMENT_WARNING_LOCK.synchronize do
        return false if @environment_warning_logged

        @environment_warning_logged = true
      end

      if configuration.logger
        configuration.logger.warn(message)
      else
        Kernel.warn(message)
      end
      true
    rescue StandardError
      false
    end

    # Records one thing that changed in a running system, e.g.
    # `ForgeOpsTracker.record_change(kind: "feature_flag", title: "Enabled new_checkout for 10%")`,
    # so ForgeOps can show it next to the errors and slowdowns that followed. kind is one of
    # Change::KINDS (anything else is sent as "other"); environment defaults to the configured one.
    # Delivered from a background thread like error events, so it never blocks the caller, and a
    # no-op when the gem isn't enabled. Never raises: returns false when nothing was queued.
    def record_change(kind:, title:, details: {}, environment: nil, service: nil, actor: nil, url: nil, id: nil, occurred_at: nil)
      return false unless configuration.enabled?

      payload = Change.build(
        configuration, kind: kind, title: title, details: details, environment: environment,
        service: service, actor: actor, url: url, id: id, occurred_at: occurred_at
      )
      return false unless payload

      change_queue.push(payload)
    rescue StandardError => e
      configuration.logger&.debug { "[ForgeOpsTracker] record_change failed: #{e.class}: #{e.message}" }
      false
    end

    # Records a named business metric (a signup, a payment, anything a customer wants to name),
    # buffered and flushed periodically as a batch rather than one network call per capture (see
    # MetricBuffer). value defaults to 1.0 so a bare counter-style call ("a signup happened")
    # needs no argument; pass an explicit one for a metric with a real magnitude ("a $49 payment
    # happened"). A no-op, same as every other capture path in this gem, when the gem isn't
    # enabled (no DSN configured, or the current environment isn't in enabled_environments).
    def capture_metric(name, value: 1.0)
      return unless configuration.enabled?

      metric_buffer.record(metric_name: name, value: value)
    end

    # Records one infrastructure reading (CPU/memory/disk, or anything else a customer's own
    # script reads) from one of their own hosts. hostname defaults to Configuration#server_name
    # (already derived from Socket.gethostname), so a script running on the box it's reporting
    # about doesn't need to pass one explicitly. Same buffered-batch delivery and no-op-when-
    # disabled contract as capture_metric above.
    def capture_infrastructure_metric(name, value:, hostname: nil)
      return unless configuration.enabled?

      infrastructure_metric_buffer.record(metric_name: name, value: value, hostname: hostname || configuration.server_name)
    end

    # Manually attaches an affected user to whatever gets reported for the rest of this request
    # (or, outside a request entirely, in a background job or a console session, for the rest of
    # this thread). Sets the same thread-local ForgeOpsTracker::Middleware::UserContext's own
    # Warden auto-detection uses, so this composes with it rather than being a second, separate
    # mechanism: call this after that middleware ran to override its guess, or call it standalone
    # in an app with no Warden at all. id/email/username are all independently optional; a call
    # with none of them (or all nil) clears whatever was set.
    def set_user(id: nil, email: nil, username: nil)
      user = { id: id, email: email, username: username }.compact
      Thread.current[:forge_ops_tracker_current_user] = user.empty? ? nil : user
    end

    # Adds one breadcrumb to the current request's trail (or, outside a request entirely, a
    # background job or console session's own trail for the rest of this thread: see
    # ForgeOpsTracker::Middleware::BreadcrumbContext for how a request gets its own buffer to start
    # with). Lazily creates a buffer on this thread if BreadcrumbContext never ran (Sidekiq/Solid
    # Queue jobs don't go through Rack middleware at all, an IRB/rails console session even less
    # so), the same "works standalone, no specific setup required" shape ForgeOpsTracker.set_user
    # already has. Works whether or not track_breadcrumbs is on: that flag only gates the automatic
    # sql.active_record/process_action.action_controller/Net::HTTP sources Railtie installs, never
    # this manual call.
    def add_breadcrumb(message, category: "custom", level: "info", data: {})
      buffer = (Thread.current[:forge_ops_tracker_breadcrumbs] ||= BreadcrumbBuffer.new(configuration))
      buffer.add(category: category, message: message, level: level, data: data)
    end

    # Wraps a customer's own service-level code as one named, nested span in the current request's
    # trace (e.g. `ForgeOpsTracker.span("PaymentService#charge") { ... }`), so its database/Redis/
    # outbound-HTTP calls show up nested underneath it in the waterfall rather than appearing to
    # hang directly off the controller root - there's no automatic way to detect "this is a
    # logically distinct service layer" the way a SQL query or an HTTP request already has a real
    # instrumentation hook to detect, so this is deliberately explicit, opt-in, by hand, unlike
    # every other span kind this gem records automatically.
    #
    # A plain pass-through (still runs the block, records nothing) with no error and no special
    # handling whenever there's no current request trace to nest under at all: outside a request
    # entirely (a background job, a console session), when track_tracing is off, or when the gem
    # isn't enabled - the same "never break the host app's own code path" posture every other
    # capture method in this gem already takes. Unlike add_breadcrumb, this does NOT lazily create
    # a standalone buffer for itself: a lone span with no request-level trace around it, and no
    # middleware left running to ever flush it, would just accumulate in this thread's memory
    # forever with nothing to ever send it, which is worse than never recording it at all.
    #
    # A span with kind: "database" can also carry the SQL it ran and which database it ran on, e.g.
    # `ForgeOpsTracker.span("Load orders", kind: "database", statement: sql, db_system: "postgresql")`.
    # The statement is masked by SqlStatement before it's kept (every string and number becomes
    # "?"), so no value it was run with is ever sent. Both are ignored on any other kind of span.
    def span(name, kind: "service", data: {}, statement: nil, db_system: nil)
      return yield unless configuration.enabled? && configuration.track_tracing

      buffer = Thread.current[:forge_ops_tracker_spans]
      return yield unless buffer

      data = database_span_data(data, statement, db_system) if kind.to_s == "database"
      span_id = SecureRandom.hex(8)
      started_at = Time.now.utc
      buffer.push(span_id)
      begin
        yield
      ensure
        buffer.pop
        duration_ms = (Time.now.utc - started_at) * 1000.0
        buffer.record(span_id: span_id, name: name, kind: kind, started_at: started_at, duration_ms: duration_ms, data: data)
      end
    end

    private
      def database_span_data(data, statement, db_system)
        system = (db_system.to_s.strip.downcase unless db_system.nil? || db_system.to_s.strip.empty?)
        extra = {
          "db.statement" => (SqlStatement.mask(statement.to_s, system: system) unless statement.nil?),
          "db.system" => system
        }.compact
        extra.empty? ? data : data.merge(extra)
      end

      def change_queue
        @change_queue ||= DeliveryQueue.new(configuration, deliver_with: :deliver_change)
      end

      def metric_buffer
        @metric_buffer ||= MetricBuffer.new(configuration)
      end

      def infrastructure_metric_buffer
        @infrastructure_metric_buffer ||= InfrastructureMetricBuffer.new(configuration)
      end
  end
end

require "forge_ops_tracker/railtie" if defined?(Rails::Railtie)
