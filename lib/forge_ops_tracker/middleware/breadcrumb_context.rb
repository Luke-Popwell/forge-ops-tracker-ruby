module ForgeOpsTracker
  module Middleware
    # Gives every request a fresh, empty BreadcrumbBuffer to accumulate into (via
    # ForgeOpsTracker.add_breadcrumb, or the automatic sql.active_record/process_action.
    # action_controller/Net::HTTP subscriptions Railtie installs), so one request's trail never
    # bleeds into another's, then hands ErrorSubscriber#report a way to read it back the exact same
    # way ForgeOpsTracker::Middleware::UserContext's own thread-local does for the current user
    # (Rails.error.subscribe's own #report interface never receives the Rack env, so this
    # thread-local is the only channel available). A sibling to SessionTracking/UserContext, not
    # folded into either: distinct concern, same "own file, own class" shape every middleware in
    # this gem already takes.
    #
    # The ensure-clear is load-bearing, not optional, same reasoning UserContext's own doc
    # comment gives: Puma reuses threads across requests, so leaving a buffer set would leak one
    # request's breadcrumbs into a later, unrelated request handled on the same thread.
    class BreadcrumbContext
      def initialize(app, configuration: ForgeOpsTracker.configuration)
        @app = app
        @configuration = configuration
      end

      def call(env)
        return app.call(env) unless configuration.track_breadcrumbs && configuration.enabled?

        Thread.current[:forge_ops_tracker_breadcrumbs] = BreadcrumbBuffer.new(configuration)
        app.call(env)
      ensure
        Thread.current[:forge_ops_tracker_breadcrumbs] = nil
      end

      private
        attr_reader :app, :configuration
    end
  end
end
