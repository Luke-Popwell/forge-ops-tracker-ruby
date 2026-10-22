module ForgeOpsTracker
  module Integrations
    module ActiveRecordPool
      # Reports this process's own ActiveRecord connection pool utilization as infrastructure
      # metrics on a periodic timer, the same shape as Sidekiq::StatsReporter/SolidQueue::StatsReporter
      # (see either's own comment), and, like both of those, only ever loaded when ActiveRecord is
      # actually present (checked with defined? in Railtie, not assumed).
      #
      # Scoped to the current process's own primary connection pool only, via the bare
      # ActiveRecord::Base.connection_pool this process is actually using: a known v1 limitation,
      # not an oversight, for an app with multiple databases (ActiveRecord::Base.connection_pool is
      # only ever one of potentially several pools such an app has configured). Reporting every
      # configured pool would need ActiveRecord::Base.connection_handler's own registry, a genuinely
      # separate piece of work; this integration reports what a single-database app (the common
      # case, and the only case this gem's own test suite/README examples ever set up) actually has.
      class StatsReporter
        def self.start(configuration: ForgeOpsTracker.configuration)
          return unless configuration.track_performance && configuration.enabled?

          PeriodicPoller.start(configuration.gauge_poll_interval, logger: configuration.logger) { new.report }
        end

        def report
          stat = ::ActiveRecord::Base.connection_pool.stat
          size = stat[:size].to_i
          busy = stat[:busy].to_i

          # 0/0 (a pool nobody's ever checked a connection out of yet, or, in practice, never) reads
          # as 0% utilized, not NaN/an error: a pool that's never been used is exactly as "not under
          # pressure" as a pool with plenty of headroom, not a value worth surfacing as broken.
          utilization_pct = size.zero? ? 0.0 : (100.0 * busy / size).round(1)

          ForgeOpsTracker.capture_infrastructure_metric("active_record_pool.utilization_pct", value: utilization_pct)
          ForgeOpsTracker.capture_infrastructure_metric("active_record_pool.size", value: size)
          ForgeOpsTracker.capture_infrastructure_metric("active_record_pool.busy", value: busy)
          ForgeOpsTracker.capture_infrastructure_metric("active_record_pool.waiting", value: stat[:waiting].to_i)
        end
      end
    end
  end
end
