module ForgeOpsTracker
  module Middleware
    # Publishes this request's RequestState (trace id, remote parent span id, transaction name,
    # endpoint, errored flag; see that class) as a thread-local for the duration of the request,
    # cleared in an ensure for the same "Puma reuses threads" reason every other middleware in this
    # gem already gives. Not gated on track_tracing: the trace id links an error to errors in other
    # services even when no spans are ever recorded.
    #
    # Its second job is the reason it has to be the *innermost* of this gem's middlewares (added
    # last in Railtie, so app.middleware.use puts it closest to the app). Rails 8.1 reports an
    # unhandled request exception from ActionDispatch::Executor, which sits outside all of this
    # gem's middlewares; by the time ErrorSubscriber#report runs for that exception, every one of
    # their ensure blocks has already cleared its thread-local, so the user, the breadcrumb trail,
    # and the trace id/endpoint would all be gone for exactly the errors that matter most. Rescuing
    # here, innermost, is the last moment all of those are still set: this copies them onto the
    # exception object itself (see SNAPSHOT_IVAR) before re-raising it unchanged, and
    # ErrorSubscriber#report falls back to that copy whenever the live thread-locals are gone.
    #
    # Rescues Exception, not StandardError, and always re-raises: this only ever observes an
    # exception on its way out, it never handles one, so there's no reason to let anything slip
    # past without its context attached.
    #
    # Outside Rails it is also what reports an unhandled request error, since there's no
    # Rails.error to do it: add it to a plain Rack or Sinatra app with
    # `use ForgeOpsTracker::Middleware::RequestContext`. It reports a StandardError escaping the
    # app, and a Sinatra error the app turned into a 5xx response itself (Sinatra keeps that in
    # env["sinatra.error"] rather than raising it when raise_errors is off, its production
    # default). report_exceptions defaults to true only when Rails isn't loaded, and the Railtie
    # passes false, so nothing is reported twice under Rails.
    class RequestContext
      THREAD_KEY = :forge_ops_tracker_request_context

      # An instance variable on the exception object, not a wrapper exception or a side table: the
      # exception is the one thing guaranteed to travel from here to wherever Rails ends up
      # reporting it, and a plain ivar leaves its class, message, and backtrace exactly as the host
      # app raised them.
      SNAPSHOT_IVAR = :@__forge_ops_tracker_request_snapshot

      FRAMEWORK_ERROR_KEY = "sinatra.error".freeze

      def initialize(app, configuration: ForgeOpsTracker.configuration, report_exceptions: !defined?(::Rails::Railtie))
        @app = app
        @configuration = configuration
        @report_exceptions = report_exceptions
        ForgeOpsTracker.warn_if_environment_disabled if report_exceptions && configuration.equal?(ForgeOpsTracker.configuration)
      end

      def call(env)
        return app.call(env) unless configuration.enabled?

        state = RequestState.for(env)
        Thread.current[THREAD_KEY] = state
        response = app.call(env)
        report_framework_error(env, response) if report_exceptions
        response
      rescue Exception => e
        if state
          state.mark_errored!
          self.class.attach_snapshot(e, state)
          report(e, env) if report_exceptions && e.is_a?(StandardError)
        end
        raise
      ensure
        Thread.current[THREAD_KEY] = nil
      end

      class << self
        def current
          Thread.current[THREAD_KEY]
        end

        # Never raises, whatever it's handed: a frozen exception (some libraries freeze theirs, and
        # a frozen object rejects instance_variable_set with a FrozenError) just goes without a
        # snapshot, and so does anything else unexpected, since failing here would replace the host
        # app's own exception with one of this gem's. The first snapshot wins if the same exception
        # object somehow passes through twice: the innermost one saw the request closest to where
        # it actually failed.
        def attach_snapshot(error, state)
          return if error.frozen? || error.instance_variable_defined?(SNAPSHOT_IVAR)

          error.instance_variable_set(SNAPSHOT_IVAR, {
            user: Thread.current[:forge_ops_tracker_current_user],
            breadcrumbs: Thread.current[:forge_ops_tracker_breadcrumbs]&.all,
            transaction_name: state.transaction_name,
            endpoint: state.endpoint,
            trace_id: state.trace_id
          }.freeze)
        rescue StandardError
          nil
        end

        def snapshot_for(error)
          return nil unless error.instance_variable_defined?(SNAPSHOT_IVAR)

          error.instance_variable_get(SNAPSHOT_IVAR)
        rescue StandardError
          nil
        end
      end

      private
        attr_reader :app, :configuration, :report_exceptions

        # Called while this request's RequestState and the other middlewares' thread-locals are
        # all still set, so the report carries the trace id, user and breadcrumbs.
        def report(error, env)
          ForgeOpsTracker.capture_exception(error, context: { "path" => env["PATH_INFO"], "method" => env["REQUEST_METHOD"] }.compact)
        rescue StandardError
          nil
        end

        def report_framework_error(env, response)
          error = env[FRAMEWORK_ERROR_KEY]
          return unless error.is_a?(StandardError) && response.is_a?(Array) && response.first.to_i >= 500

          RequestContext.current&.mark_errored!
          report(error, env)
        end
    end
  end
end
