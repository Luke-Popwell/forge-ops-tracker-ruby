module ForgeOpsTracker
  module Middleware
    # Wraps every request: counts it, and separately counts it as crashed only when an exception
    # actually escapes to here, never inferred from whether ErrorSubscriber happened to report
    # anything, since ErrorSubscriber reports handled errors too (see Rails.error.handle), so "an
    # event was reported" and "this request crashed" aren't the same signal. Always re-raises,
    # so the host app's own error handling and ErrorSubscriber both run completely unaffected by
    # this middleware's presence; it only ever observes, never intercepts.
    class SessionTracking
      def initialize(app, configuration: ForgeOpsTracker.configuration, flusher: nil)
        @app = app
        @configuration = configuration
        @flusher = flusher
      end

      def call(env)
        return app.call(env) unless configuration.track_sessions && configuration.enabled?

        begin
          response = app.call(env)
        rescue StandardError
          flusher_instance.record_session(crashed: true)
          raise
        end

        flusher_instance.record_session(crashed: false)
        response
      end

      private
        attr_reader :app, :configuration

        def flusher_instance
          @flusher ||= SessionFlusher.new(configuration)
        end
    end
  end
end
