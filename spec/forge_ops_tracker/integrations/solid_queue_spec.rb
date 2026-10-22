require "spec_helper"
require "forge_ops_tracker/integrations/solid_queue"

RSpec.describe ForgeOpsTracker::Integrations::SolidQueue::StatsReporter do
  # The real solid_queue gem can't be required here at all without Rails itself loaded
  # (SolidQueue::Engine < Rails::Engine at the top of the gem, confirmed directly): adding rails
  # as another dev dependency just to stub query results on top of it would be a lot of weight for
  # no real gain, since this reporter's own logic doesn't touch anything solid_queue-internal
  # beyond the handful of class/method names it calls. Defining bare stand-in classes under the
  # SolidQueue namespace instead, the same "stub the exact name, not the real dependency" approach
  # the Sidekiq middleware spec already uses for ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper.
  before do
    # verify_partial_doubles (see spec_helper) checks a stubbed method against the real class it's
    # stubbed onto, even a bare stand-in class like these: each needs the one class method this
    # reporter actually calls defined for real (an empty body; the real return value comes from
    # the `allow(...).to receive(...)` stub in each example below, not from these).
    stub_const("SolidQueue::Process", Class.new { def self.where(*); end })
    stub_const("SolidQueue::FailedExecution", Class.new { def self.count; end })
    stub_const("SolidQueue::ScheduledExecution", Class.new { def self.count; end })
    stub_const("SolidQueue::BlockedExecution", Class.new { def self.count; end })
    stub_const("SolidQueue::Queue", Class.new { def self.all; end })
  end

  it "reports active worker/dispatcher counts, failed/scheduled/blocked counts, and one queue_depth entry per queue" do
    # Plain (non-verifying) doubles throughout, not class_double/instance_double: those stubbed
    # classes above have no real methods of their own to verify a double against, since they're
    # bare stand-ins for the actual solid_queue constant names, not the real classes.
    worker_relation = double("worker_relation", count: 3)
    dispatcher_relation = double("dispatcher_relation", count: 1)
    allow(::SolidQueue::Process).to receive(:where).with(kind: "Worker").and_return(worker_relation)
    allow(::SolidQueue::Process).to receive(:where).with(kind: "Dispatcher").and_return(dispatcher_relation)
    allow(::SolidQueue::FailedExecution).to receive(:count).and_return(2)
    allow(::SolidQueue::ScheduledExecution).to receive(:count).and_return(5)
    allow(::SolidQueue::BlockedExecution).to receive(:count).and_return(1)
    queue = double("queue", name: "default", size: 8)
    allow(::SolidQueue::Queue).to receive(:all).and_return([ queue ])

    recorded = {}
    allow(ForgeOpsTracker).to receive(:capture_infrastructure_metric) { |name, value:| recorded[name] = value }

    described_class.new.report

    expect(recorded).to include(
      "solid_queue.active_workers" => 3, "solid_queue.active_dispatchers" => 1,
      "solid_queue.failed" => 2, "solid_queue.scheduled" => 5, "solid_queue.blocked" => 1,
      "solid_queue.queue_depth.default" => 8
    )
  end
end
