# Sidekiq::Stats/Sidekiq::Queue (used by StatsReporter below) live in sidekiq/api, not
# autoloaded by a bare "sidekiq" require; a real Sidekiq server process almost always already has
# this loaded some other way, but requiring it explicitly here doesn't depend on that happening to
# be true.
require "sidekiq/api"

module ForgeOpsTracker
  module Integrations
    module Sidekiq
      # Times a raw (non-ActiveJob) Sidekiq::Worker's own #perform. Registered via
      # Sidekiq.configure_server { |c| c.server_middleware { |chain| chain.add ... } } (see
      # Railtie); only ever loaded when Sidekiq is already present (checked with defined? there),
      # matching every other optional integration in this gem.
      #
      # Skips (yields, but doesn't record) any job whose worker is ActiveJob's own Sidekiq wrapper:
      # see PerformanceInstrumentation.sidekiq_worker_is_active_job_wrapper?'s own comment for why
      # that job is already counted by the perform.active_job subscription instead, and would be
      # double-counted here otherwise.
      class Middleware
        include ::Sidekiq::ServerMiddleware

        def initialize(configuration: ForgeOpsTracker.configuration, flusher: Railtie.performance_flusher)
          @configuration = configuration
          @flusher = flusher
        end

        def call(job_instance, _msg, _queue)
          skip = !@configuration.track_performance || !@configuration.enabled? ||
            PerformanceInstrumentation.sidekiq_worker_is_active_job_wrapper?(job_instance)
          start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) unless skip

          yield
        ensure
          unless skip
            duration_ms = (::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - start) * 1000.0
            @flusher.record(transaction_name: job_instance.class.name, duration_ms: duration_ms, kind: "job")
          end
        end
      end

      # Reports Sidekiq's own aggregate stats (Sidekiq::Stats, Sidekiq::Queue) as gauge-style
      # infrastructure metrics on a periodic timer (see PeriodicPoller), via the same public
      # ForgeOpsTracker.capture_infrastructure_metric every customer's own manual infrastructure-
      # monitoring script already uses; no new ingestion endpoint or dashboard dataset needed.
      class StatsReporter
        def self.start(configuration: ForgeOpsTracker.configuration)
          return unless configuration.track_performance && configuration.enabled?

          PeriodicPoller.start(configuration.gauge_poll_interval, logger: configuration.logger) { new.report }
        end

        def report
          stats = ::Sidekiq::Stats.new

          ForgeOpsTracker.capture_infrastructure_metric("sidekiq.processed", value: stats.processed)
          ForgeOpsTracker.capture_infrastructure_metric("sidekiq.failed", value: stats.failed)
          ForgeOpsTracker.capture_infrastructure_metric("sidekiq.scheduled_size", value: stats.scheduled_size)
          ForgeOpsTracker.capture_infrastructure_metric("sidekiq.retry_size", value: stats.retry_size)
          ForgeOpsTracker.capture_infrastructure_metric("sidekiq.dead_size", value: stats.dead_size)
          ForgeOpsTracker.capture_infrastructure_metric("sidekiq.workers_size", value: stats.workers_size)

          ::Sidekiq::Queue.all.each do |queue|
            ForgeOpsTracker.capture_infrastructure_metric("sidekiq.queue_depth.#{queue.name}", value: queue.size)
          end
        end
      end
    end
  end
end
