module ForgeOpsTracker
  # A bounded, in-order trail of whatever happened recently on this thread: SQL queries,
  # controller actions, outgoing HTTP requests, and anything added by hand via
  # ForgeOpsTracker.add_breadcrumb, all recorded automatically once ForgeOpsTracker::Railtie's own
  # subscriptions are installed. The direct Ruby analog to sdks/typescript's own BreadcrumbBuffer
  # (a ring buffer capped at Configuration#max_breadcrumbs, oldest entry dropped once full), but
  # per-thread rather than per-page-lifetime: a browser tab has one continuous session to trail,
  # but a Rails server handles many concurrent, unrelated requests on a thread pool, the same
  # "Thread.current, not a plain global" reasoning ForgeOpsTracker.set_user's own thread-local
  # already documents. ForgeOpsTracker::Middleware::BreadcrumbContext resets this to a fresh, empty
  # buffer at the start of every request, so one request's trail never bleeds into another's on a
  # reused Puma thread, and clears it again in an ensure so it doesn't leak into whatever runs next
  # on that thread outside a request either (a console session, a background job).
  class BreadcrumbBuffer
    def initialize(configuration)
      @configuration = configuration
      @entries = []
    end

    def add(category:, message:, level: "info", data: {})
      # Read fresh on every add, not captured once at construction: the same reasoning
      # DeliveryQueue re-reads Configuration#queue_size on every push, so a config change from
      # ForgeOpsTracker.configure takes effect on whatever's added next, not just a buffer created
      # afterward.
      max_size = [ configuration.max_breadcrumbs, 0 ].max
      # Strict privacy never sends breadcrumbs, so they're never recorded either.
      return if max_size.zero? || configuration.strict_privacy

      entries << {
        category: category.to_s,
        message: message.to_s,
        level: level.to_s,
        timestamp: Time.now.utc.iso8601,
        data: data || {}
      }
      entries.shift while entries.length > max_size
    end

    def all
      entries.dup
    end

    private
      attr_reader :configuration, :entries
  end
end
