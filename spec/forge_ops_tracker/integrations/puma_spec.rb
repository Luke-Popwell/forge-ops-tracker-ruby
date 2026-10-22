require "spec_helper"
require "puma"
require "forge_ops_tracker/integrations/puma"

RSpec.describe ForgeOpsTracker::Integrations::Puma::StatsReporter do
  def recorded_metrics
    recorded = {}
    allow(ForgeOpsTracker).to receive(:capture_infrastructure_metric) { |name, value:| recorded[name] = value }
    described_class.new.report
    recorded
  end

  it "reports backlog/running/pool_capacity directly from a single-mode (top-level) stats hash" do
    allow(::Puma).to receive(:stats_hash).and_return(backlog: 2, running: 5, pool_capacity: 3, max_threads: 5)

    expect(recorded_metrics).to eq("puma.backlog" => 2, "puma.running_threads" => 5, "puma.pool_capacity" => 3)
  end

  it "sums backlog/running/pool_capacity across workers' own last_status in clustered mode" do
    allow(::Puma).to receive(:stats_hash).and_return(
      workers: 2,
      worker_status: [
        { last_status: { backlog: 1, running: 3, pool_capacity: 2 } },
        { last_status: { backlog: 0, running: 4, pool_capacity: 1 } }
      ]
    )

    expect(recorded_metrics).to eq("puma.backlog" => 1, "puma.running_threads" => 7, "puma.pool_capacity" => 3)
  end

  it "reports nothing when a clustered worker's own last_status is still empty (hasn't checked in yet)" do
    allow(::Puma).to receive(:stats_hash).and_return(
      workers: 1,
      worker_status: [ { last_status: {} } ]
    )

    expect(recorded_metrics).to eq({})
  end

  it "reports nothing when stats_hash itself is nil" do
    allow(::Puma).to receive(:stats_hash).and_return(nil)

    expect(recorded_metrics).to eq({})
  end
end
