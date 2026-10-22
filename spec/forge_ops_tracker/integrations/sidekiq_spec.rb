require "spec_helper"
require "sidekiq"
require "forge_ops_tracker/integrations/sidekiq" # itself requires sidekiq/api, see that file's own comment

RSpec.describe ForgeOpsTracker::Integrations::Sidekiq::Middleware do
  let(:configuration) do
    ForgeOpsTracker::Configuration.new.tap do |c|
      c.track_performance = true
      c.dsn = "https://key@tracker.example.com/api/v1/events"
      c.enabled_environments = %w[test]
      c.environment = "test"
    end
  end
  let(:flusher) { instance_double(ForgeOpsTracker::PerformanceFlusher, record: nil) }

  class FakeSidekiqWorker
    def perform(*); end
  end

  def call(worker, &block)
    described_class.new(configuration: configuration, flusher: flusher).call(worker, {}, "default", &(block || -> { }))
  end

  it "records a raw Sidekiq worker's own class name and duration, kind: job" do
    call(FakeSidekiqWorker.new)

    expect(flusher).to have_received(:record).with(transaction_name: "FakeSidekiqWorker", duration_ms: kind_of(Numeric), kind: "job")
  end

  it "still yields to run the actual job" do
    ran = false

    call(FakeSidekiqWorker.new) { ran = true }

    expect(ran).to be true
  end

  it "skips recording (but still runs the job) when disabled" do
    configuration.track_performance = false

    call(FakeSidekiqWorker.new)

    expect(flusher).not_to have_received(:record)
  end

  it "skips recording an ActiveJob-dispatched job, since perform.active_job already covers it" do
    stub_const("ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper", Class.new { def perform(*); end })
    wrapper = ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper.new

    call(wrapper)

    expect(flusher).not_to have_received(:record)
  end

  it "still yields (running the job) even when skipping the ActiveJob-wrapper case" do
    stub_const("ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper", Class.new { def perform(*); end })
    wrapper = ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper.new
    ran = false

    call(wrapper) { ran = true }

    expect(ran).to be true
  end
end

RSpec.describe ForgeOpsTracker::Integrations::Sidekiq::StatsReporter do
  # Sidekiq::Stats/Queue both read from Redis; a real Redis isn't available in this test
  # environment, so the reporter's own #report is exercised against doubles standing in for
  # those two classes rather than a live connection, the same "no real external service needed
  # for a unit test" approach the gem's own Client specs already use for HTTP.
  it "reports every Sidekiq::Stats figure and one queue_depth entry per queue" do
    stats = instance_double(::Sidekiq::Stats, processed: 100, failed: 2, scheduled_size: 3, retry_size: 4, dead_size: 1, workers_size: 5)
    allow(::Sidekiq::Stats).to receive(:new).and_return(stats)
    queue = instance_double(::Sidekiq::Queue, name: "default", size: 7)
    allow(::Sidekiq::Queue).to receive(:all).and_return([ queue ])

    recorded = {}
    allow(ForgeOpsTracker).to receive(:capture_infrastructure_metric) { |name, value:| recorded[name] = value }

    described_class.new.report

    expect(recorded).to include(
      "sidekiq.processed" => 100, "sidekiq.failed" => 2, "sidekiq.scheduled_size" => 3,
      "sidekiq.retry_size" => 4, "sidekiq.dead_size" => 1, "sidekiq.workers_size" => 5,
      "sidekiq.queue_depth.default" => 7
    )
  end
end
