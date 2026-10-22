module ForgeOpsTracker
  # Implements the subscriber interface Rails.error.subscribe expects
  # (#report). An error reporter that itself raises while reporting an
  # error is the worst possible failure mode, so every path here is
  # wrapped to guarantee this never propagates an exception back into the
  # host app's error-handling cycle.
  class ErrorSubscriber
    # Sidekiq raises its own control-flow exception once it has already scheduled a failed job's
    # retry (Sidekiq::JobRetry::Handled, and Sidekiq::JobRetry::Skip, a subclass, for a job that
    # opted out of retries), and Rails' executor, which Sidekiq's Rails integration wraps every
    # job in, reports whatever escapes that wrap. Left alone, every failing Sidekiq job, whatever
    # actually went wrong inside it, reaches ForgeOps as the same opaque "Sidekiq::JobRetry::
    # Handled" issue with the real error nowhere in it. The real error is that exception's #cause
    # (Sidekiq raises it from inside its own rescue), so it's unwrapped here, by class name
    # rather than constant since Sidekiq is an optional dependency this gem never requires.
    RETRY_CONTROL_FLOW_CLASS = "Sidekiq::JobRetry::Handled".freeze

    def initialize(configuration, delivery_queue: DeliveryQueue.new(configuration), event_builder: EventBuilder.new(configuration))
      @configuration = configuration
      @delivery_queue = delivery_queue
      @event_builder = event_builder
    end

    def report(error, handled: true, severity: nil, context: {}, source: nil)
      return unless configuration.enabled?

      # Read here, not inside EventBuilder: Rails.error.subscribe's own #report interface never
      # hands this class the Rack env, so ForgeOpsTracker::Middleware::UserContext (Warden
      # auto-detection) and ForgeOpsTracker.set_user (the manual override/fallback) both
      # communicate with this exact same thread-local instead, the only channel available here.
      # ForgeOpsTracker::Middleware::BreadcrumbContext's own per-request buffer works the same way,
      # and so does Middleware::RequestContext's RequestState (trace id, transaction name,
      # endpoint).
      #
      # Each live thread-local wins when it's set; the snapshot Middleware::RequestContext attached
      # to the exception on its way out of the request is the fallback. That fallback is the whole
      # story for an unhandled request error on Rails 8.1: ActionDispatch::Executor reports it from
      # outside every middleware this gem installs, after all of their ensure blocks have already
      # cleared every one of these thread-locals (see that middleware's own comment).
      original_error = error
      error = unwrap_retry_control_flow(error)
      snapshot = Middleware::RequestContext.snapshot_for(original_error) || Middleware::RequestContext.snapshot_for(error) || {}
      state = Middleware::RequestContext.current

      # A handled error reported during a request (Rails.error.handle/record/report) is what marks
      # it errored here; an unhandled one was already marked by RequestContext's own rescue. Either
      # way Middleware::SpanTracing then sends this request's trace however fast it was.
      state&.mark_errored!

      user = Thread.current[:forge_ops_tracker_current_user] || snapshot[:user]
      breadcrumbs = Thread.current[:forge_ops_tracker_breadcrumbs]&.all || snapshot[:breadcrumbs] || []
      delivery_queue.push(event_builder.build(
        error, context: context, user: user, breadcrumbs: breadcrumbs,
        transaction_name: state&.transaction_name || snapshot[:transaction_name],
        endpoint: state&.endpoint || snapshot[:endpoint],
        trace_id: state&.trace_id || snapshot[:trace_id]
      ))
      nil
    rescue StandardError => e
      configuration.logger&.debug { "[ForgeOpsTracker] report failed: #{e.class}: #{e.message}" }
      nil
    end

    private
      attr_reader :configuration, :delivery_queue, :event_builder

      # Only ever unwraps when there is a real #cause to unwrap to; a Handled with no cause (not
      # something Sidekiq itself does) is reported as-is rather than dropped.
      def unwrap_retry_control_flow(error)
        while error.cause && error.class.ancestors.any? { |ancestor| ancestor.name == RETRY_CONTROL_FLOW_CLASS }
          error = error.cause
        end
        error
      end
  end
end
