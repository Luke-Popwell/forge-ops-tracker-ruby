module ForgeOpsTracker
  module Middleware
    # Wraps every request: if Warden is mounted (env["warden"] present, whether or not the app
    # uses Devise specifically, since Devise just mounts Warden automatically, but any Warden-
    # based auth setup works here, confirmed directly against the installed warden gem's own
    # Warden::Manager/Warden::Proxy source) and it has a signed-in user, stashes a serialized
    # version of that user in a thread-local for the duration of this request so
    # ErrorSubscriber#report (which never receives the Rack env at all: Rails.error.subscribe's
    # own interface hands it error/context/severity, nothing request-shaped) can read it back and
    # attach it to whatever gets reported. A sibling to SessionTracking, not folded into it:
    # distinct concern, same "own file, own class" shape every middleware in this gem already
    # takes.
    #
    # The ensure-clear is load-bearing, not optional: Puma reuses threads across requests, so
    # leaving this set would leak one request's user into a later, unrelated request handled on
    # the same thread.
    class UserContext
      def initialize(app, configuration: ForgeOpsTracker.configuration)
        @app = app
        @configuration = configuration
      end

      def call(env)
        return app.call(env) unless configuration.track_current_user && configuration.enabled?

        if env.key?("warden") && (user = env["warden"].user)
          serialized = serialize(user)
          Thread.current[:forge_ops_tracker_current_user] = serialized unless serialized.empty?
        end

        app.call(env)
      ensure
        Thread.current[:forge_ops_tracker_current_user] = nil
      end

      private
        attr_reader :app, :configuration

        # Duck-types rather than assuming a Devise-shaped model: id if the object responds to it,
        # email if it responds to it, username else name if either responds to it. A custom
        # Warden setup with a differently-shaped user object just gets whatever subset applies
        # here; ForgeOpsTracker.set_user covers anything this can't infer.
        def serialize(user)
          {
            id: (user.id if user.respond_to?(:id)),
            email: (user.email if user.respond_to?(:email)),
            username: (user.username if user.respond_to?(:username)) || (user.name if user.respond_to?(:name))
          }.compact
        end
    end
  end
end
