module ForgeOpsTracker
  module Integrations
    module RedisClientTiming
      # Times every Redis command, applied once via RedisClient.prepend(Timing) from Railtie, the
      # same Module#prepend + super shape Integrations::NetHTTP::Timing already uses for the
      # identical reason: neither Ruby's Redis ecosystem nor RedisClient itself fires an
      # ActiveSupport::Notifications event of its own, so wrapping #call directly is the only hook
      # available. Targets RedisClient specifically (the modern, actively-maintained low-level
      # client both the current redis gem (5.x+) and standalone RedisClient users go through), not
      # the older redis-rb 4.x Redis::Client - confirmed directly (not assumed) that redis 5.x no
      # longer defines Redis::Client at all, so a hook there would silently do nothing on any
      # currently-installed version of the gem.
      #
      # Unlike controller/query timing, this is span-only: there's no "redis" PerformanceSample
      # kind for this to feed into the aggregate Performance page (that page has no Redis panel at
      # all yet), so this only ever contributes to a captured trace's own waterfall, plus a
      # breadcrumb and a dependency failure record, the same two other independent mechanisms
      # NetHTTP::Timing's own call site already establishes.
      #
      # name is "Redis <COMMAND>" (the command verb alone, upcased: GET, SET, LPUSH, ...), never
      # the key or any argument - the same low-cardinality, no-secrets-in-a-label reasoning every
      # other transaction_name/span name in this gem already follows; a Redis key can easily carry
      # a customer's own id or other sensitive value.
      def call(*command, **kwargs)
        configuration = ForgeOpsTracker.configuration
        return super unless (configuration.track_breadcrumbs || configuration.track_failures || configuration.track_tracing) && configuration.enabled?

        name = "Redis #{command.first.to_s.upcase}"
        start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        result = super
      rescue StandardError => e
        raised_error = e
        raise
      ensure
        if start
          duration_ms = (::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - start) * 1000.0

          if configuration.track_breadcrumbs
            ForgeOpsTracker.add_breadcrumb(
              name, category: "redis", level: raised_error ? "error" : "info",
              data: { duration_ms: duration_ms.round(1) }
            )
          end

          if configuration.track_failures && raised_error
            Railtie.failure_event_buffer.record(
              kind: "dependency", transaction_name: name,
              error_class: raised_error.class.name, error_message: raised_error.message
            )
          end

          if configuration.track_tracing && (buffer = Thread.current[:forge_ops_tracker_spans])
            buffer.record(
              span_id: SecureRandom.hex(8), name: name, kind: "redis",
              started_at: ::Time.now.utc - (duration_ms / 1000.0), duration_ms: duration_ms
            )
          end
        end
      end
    end
  end
end
