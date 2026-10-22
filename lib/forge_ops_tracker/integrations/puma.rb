module ForgeOpsTracker
  module Integrations
    module Puma
      # Reports Puma's own backlog/running-threads/pool-capacity as gauge-style infrastructure
      # metrics on a periodic timer (see PeriodicPoller). Only ever loaded when Puma is already
      # present (checked with defined? in Railtie).
      #
      # Puma.stats_hash's own shape genuinely differs by deployment mode, confirmed directly
      # against Puma 6.6.1's real source rather than assumed: single-mode (Puma::Single, no
      # `workers` config) has backlog/running/pool_capacity at the top level (Server#stats merged
      # with ThreadPool#stats); clustered mode (Puma::Cluster) has none of those at the top level
      # at all, only a worker_status array, one entry per forked worker, each carrying its own
      # last_status hash with the identical three keys (parsed from that worker's own periodic
      # IPC ping, see Puma::Cluster::WorkerHandle's own STATUS_PATTERN), summed across workers
      # here for one whole-process reading, rather than reported per worker, since ForgeOps'
      # infrastructure dataset already aggregates by hostname, not by worker index. Puma.stats_object
      # is set unconditionally by Puma::Launcher on every normal boot (not just when a control/
      # stats app is configured), so Puma.stats_hash is populated by the time this ever runs; still
      # guarded against nil/an unrecognized shape, both because that wiring could change in a
      # future Puma version and because this must never be the thing that crashes a poll tick.
      class StatsReporter
        def self.start(configuration: ForgeOpsTracker.configuration)
          return unless configuration.track_performance && configuration.enabled?

          PeriodicPoller.start(configuration.gauge_poll_interval, logger: configuration.logger) { new.report }
        end

        def report
          stats = ::Puma.stats_hash
          return unless stats

          if stats[:backlog] && stats[:running]
            report_metrics(stats[:backlog], stats[:running], stats[:pool_capacity])
          elsif stats[:worker_status]
            statuses = stats[:worker_status].filter_map { |worker| worker[:last_status] }.reject(&:empty?)
            return if statuses.empty?

            report_metrics(
              statuses.sum { |s| s[:backlog] || 0 },
              statuses.sum { |s| s[:running] || 0 },
              statuses.sum { |s| s[:pool_capacity] || 0 }
            )
          end
        end

        private
          def report_metrics(backlog, running, pool_capacity)
            ForgeOpsTracker.capture_infrastructure_metric("puma.backlog", value: backlog)
            ForgeOpsTracker.capture_infrastructure_metric("puma.running_threads", value: running)
            ForgeOpsTracker.capture_infrastructure_metric("puma.pool_capacity", value: pool_capacity)
          end
      end
    end
  end
end
