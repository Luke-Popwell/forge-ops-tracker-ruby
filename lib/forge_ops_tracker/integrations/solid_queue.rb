module ForgeOpsTracker
  module Integrations
    module SolidQueue
      # Reports Solid Queue's own gauge-style state as infrastructure metrics on a periodic timer
      # (see PeriodicPoller and Sidekiq::StatsReporter's own comment, the same shape). Only ever
      # loaded when Solid Queue is already present (checked with defined? in Railtie).
      #
      # No job *duration*/*count* reporting here: Solid Queue jobs are ActiveJob jobs, already
      # covered end to end by the perform.active_job subscription in Railtie regardless of which
      # backend actually runs them, so there's nothing left for this integration to time.
      #
      # kind is Solid Queue's own attribute on a registered process (a plain String, "Worker" or
      # "Dispatcher": confirmed directly against solid_queue's own Processes::Base#kind, which is
      # literally self.class.name.demodulize, not assumed from its docs), so this reads it exactly
      # as Solid Queue itself defines it rather than re-deriving it a different way.
      class StatsReporter
        def self.start(configuration: ForgeOpsTracker.configuration)
          return unless configuration.track_performance && configuration.enabled?

          PeriodicPoller.start(configuration.gauge_poll_interval, logger: configuration.logger) { new.report }
        end

        def report
          ForgeOpsTracker.capture_infrastructure_metric("solid_queue.active_workers", value: ::SolidQueue::Process.where(kind: "Worker").count)
          ForgeOpsTracker.capture_infrastructure_metric("solid_queue.active_dispatchers", value: ::SolidQueue::Process.where(kind: "Dispatcher").count)
          ForgeOpsTracker.capture_infrastructure_metric("solid_queue.failed", value: ::SolidQueue::FailedExecution.count)
          ForgeOpsTracker.capture_infrastructure_metric("solid_queue.scheduled", value: ::SolidQueue::ScheduledExecution.count)
          ForgeOpsTracker.capture_infrastructure_metric("solid_queue.blocked", value: ::SolidQueue::BlockedExecution.count)

          ::SolidQueue::Queue.all.each do |queue|
            ForgeOpsTracker.capture_infrastructure_metric("solid_queue.queue_depth.#{queue.name}", value: queue.size)
          end
        end
      end
    end
  end
end
