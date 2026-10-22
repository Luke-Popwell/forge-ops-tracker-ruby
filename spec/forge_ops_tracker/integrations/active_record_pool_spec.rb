require "spec_helper"
require "forge_ops_tracker/integrations/active_record_pool"

RSpec.describe ForgeOpsTracker::Integrations::ActiveRecordPool::StatsReporter do
  # Same "stub the exact name, not the real dependency" approach solid_queue_spec.rb already uses:
  # a real ActiveRecord::Base.connection_pool needs an actual established database connection to
  # even exist, which this reporter's own logic (a handful of Hash key reads off #stat) has no
  # real need for in its own test.
  before do
    connection_pool = double("connection_pool")
    stub_const("ActiveRecord::Base", Class.new { def self.connection_pool; end })
    allow(::ActiveRecord::Base).to receive(:connection_pool).and_return(connection_pool)
    @connection_pool = connection_pool
  end

  it "reports pool size, busy count, waiting count, and utilization percent" do
    allow(@connection_pool).to receive(:stat).and_return(size: 10, busy: 4, waiting: 1, idle: 6, dead: 0, checkout_timeout: 5)

    recorded = {}
    allow(ForgeOpsTracker).to receive(:capture_infrastructure_metric) { |name, value:| recorded[name] = value }

    described_class.new.report

    expect(recorded).to eq(
      "active_record_pool.utilization_pct" => 40.0,
      "active_record_pool.size" => 10,
      "active_record_pool.busy" => 4,
      "active_record_pool.waiting" => 1
    )
  end

  it "reports 0% utilization, not a division error, for a pool with size 0" do
    allow(@connection_pool).to receive(:stat).and_return(size: 0, busy: 0, waiting: 0)

    recorded = {}
    allow(ForgeOpsTracker).to receive(:capture_infrastructure_metric) { |name, value:| recorded[name] = value }

    described_class.new.report

    expect(recorded["active_record_pool.utilization_pct"]).to eq(0.0)
  end

  describe ".start" do
    it "does nothing when track_performance is off" do
      configuration = ForgeOpsTracker::Configuration.new.tap { |c| c.track_performance = false }

      expect(ForgeOpsTracker::PeriodicPoller).not_to receive(:start)
      described_class.start(configuration: configuration)
    end
  end
end
