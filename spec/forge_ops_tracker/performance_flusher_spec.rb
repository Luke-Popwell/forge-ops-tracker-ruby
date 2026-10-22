require "spec_helper"
require "timeout"

RSpec.describe ForgeOpsTracker::PerformanceFlusher do
  let(:configuration) do
    ForgeOpsTracker::Configuration.new.tap do |c|
      c.release = "1.2.3"
      c.environment = "production"
    end
  end

  describe "#record and #flush" do
    it "buckets by transaction_name and delivers one aggregate entry per transaction, resetting after a successful flush" do
      delivered = Queue.new
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_performance_samples) { |samples| delivered << samples; true }

      flusher = described_class.new(configuration, client: client)
      flusher.record(transaction_name: "PostsController#show", duration_ms: 100.0)
      flusher.record(transaction_name: "PostsController#show", duration_ms: 200.0)
      flusher.record(transaction_name: "PostsController#index", duration_ms: 50.0)
      flusher.flush

      samples = delivered.pop.sort_by { |s| s[:transaction_name] }
      expect(samples.size).to eq(2)

      index_sample = samples.find { |s| s[:transaction_name] == "PostsController#index" }
      expect(index_sample).to include(request_count: 1, duration_sum_ms: 50.0, max_duration_ms: 50.0,
        release: "1.2.3", environment: "production")

      show_sample = samples.find { |s| s[:transaction_name] == "PostsController#show" }
      expect(show_sample).to include(request_count: 2, duration_sum_ms: 300.0, max_duration_ms: 200.0)

      # Nothing new was recorded since the successful flush above, so this one sends nothing.
      flusher.flush
      expect(delivered).to be_empty
    end

    it "accumulates a latency histogram alongside count/sum/max, bucketed via HistogramBucketer" do
      delivered = Queue.new
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_performance_samples) { |samples| delivered << samples; true }

      flusher = described_class.new(configuration, client: client)
      flusher.record(transaction_name: "PostsController#show", duration_ms: 10.0)  # bucket "50"
      flusher.record(transaction_name: "PostsController#show", duration_ms: 60.0)  # bucket "100"
      flusher.record(transaction_name: "PostsController#show", duration_ms: 90.0)  # bucket "100"
      flusher.flush

      sample = delivered.pop.first
      expect(sample[:histogram]).to eq({ "50" => 1, "100" => 2 })
    end

    it "does nothing on a flush with nothing recorded" do
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_performance_samples)

      described_class.new(configuration, client: client).flush

      expect(client).not_to have_received(:deliver_performance_samples)
    end

    it "keeps every bucket for the next flush instead of losing them when delivery fails" do
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_performance_samples).and_return(false)

      flusher = described_class.new(configuration, client: client)
      flusher.record(transaction_name: "PostsController#show", duration_ms: 100.0)
      flusher.flush

      delivered_samples = nil
      allow(client).to receive(:deliver_performance_samples) { |samples| delivered_samples = samples; true }
      flusher.record(transaction_name: "PostsController#show", duration_ms: 100.0)
      flusher.flush

      expect(delivered_samples.first).to include(request_count: 2, duration_sum_ms: 200.0)
    end
  end

  describe "kind" do
    it "defaults to controller when not given" do
      delivered = Queue.new
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_performance_samples) { |samples| delivered << samples; true }

      flusher = described_class.new(configuration, client: client)
      flusher.record(transaction_name: "PostsController#show", duration_ms: 100.0)
      flusher.flush

      expect(delivered.pop.first).to include(kind: "controller")
    end

    it "buckets separately by [transaction_name, kind], so a job and a controller sharing a name never collide" do
      delivered = Queue.new
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_performance_samples) { |samples| delivered << samples; true }

      flusher = described_class.new(configuration, client: client)
      flusher.record(transaction_name: "Reports", duration_ms: 100.0, kind: "controller")
      flusher.record(transaction_name: "Reports", duration_ms: 50.0, kind: "job")
      flusher.flush

      samples = delivered.pop
      expect(samples.size).to eq(2)
      controller_sample = samples.find { |s| s[:kind] == "controller" }
      job_sample = samples.find { |s| s[:kind] == "job" }
      expect(controller_sample).to include(transaction_name: "Reports", request_count: 1, duration_sum_ms: 100.0)
      expect(job_sample).to include(transaction_name: "Reports", request_count: 1, duration_sum_ms: 50.0)
    end

    it "drops a batch the server rejected instead of sending it again" do
      delivered = []
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_performance_samples) { |batch| delivered << batch.dup; :rejected }

      flusher = described_class.new(configuration, client: client)
      flusher.record(transaction_name: "PostsController#show", duration_ms: 100.0)
      flusher.flush
      flusher.record(transaction_name: "PostsController#index", duration_ms: 50.0)
      flusher.flush
      flusher.flush

      expect(delivered.map { |batch| batch.sum { |sample| sample[:request_count] } }).to eq([ 1, 1 ])
    end

    it "keeps a batch through a failure that may pass, but drops it at the fifth flush in a row that failed" do
      delivered = []
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_performance_samples) { |batch| delivered << batch.dup; :failed }

      flusher = described_class.new(configuration, client: client)
      flusher.record(transaction_name: "PostsController#show", duration_ms: 100.0)
      5.times { flusher.flush }
      flusher.flush

      # Sent on each of the five failing flushes, then gone: the sixth has nothing to send.
      expect(delivered.map { |batch| batch.sum { |sample| sample[:request_count] } }).to eq([ 1, 1, 1, 1, 1 ])
    end

    it "starts counting failed flushes again after one that got through" do
      results = [ :failed, :failed, :failed, :failed, :delivered, :failed, :failed, :failed, :failed, :delivered ]
      delivered = []
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_performance_samples) { |batch| delivered << batch.dup; results.shift }

      flusher = described_class.new(configuration, client: client)
      flusher.record(transaction_name: "PostsController#show", duration_ms: 100.0)
      5.times { flusher.flush }
      flusher.record(transaction_name: "PostsController#index", duration_ms: 50.0)
      5.times { flusher.flush }

      expect(delivered.size).to eq(10)
      expect(results).to be_empty
    end
  end

  describe "background flushing" do
    it "flushes periodically on its own lazily-started background thread" do
      configuration.performance_flush_interval = 0.05
      delivered = Queue.new
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_performance_samples) { |samples| delivered << samples; true }

      flusher = described_class.new(configuration, client: client)
      flusher.record(transaction_name: "PostsController#show", duration_ms: 100.0)

      expect(Timeout.timeout(1) { delivered.pop }.first).to include(request_count: 1)
    end
  end

  describe "a record that lands while delivery is in flight" do
    it "is never lost: only what the snapshot delivered is subtracted, not the whole hash reset" do
      flusher = nil
      delivered = []
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_performance_samples) do |samples|
        delivered << samples
        if delivered.size == 1
          # The exact window between the snapshot and delivery succeeding.
          flusher.record(transaction_name: "PostsController#show", duration_ms: 25.0)
          flusher.record(transaction_name: "PostsController#new", duration_ms: 7.0)
        end
        true
      end

      flusher = described_class.new(configuration, client: client)
      flusher.record(transaction_name: "PostsController#show", duration_ms: 10.0)
      flusher.flush
      flusher.flush

      first, second = delivered
      expect(first.map { |s| [ s[:transaction_name], s[:request_count] ] }).to eq([ [ "PostsController#show", 1 ] ])
      expect(second.map { |s| [ s[:transaction_name], s[:request_count], s[:duration_sum_ms] ] })
        .to contain_exactly([ "PostsController#show", 1, 25.0 ], [ "PostsController#new", 1, 7.0 ])
      expect(second.find { |s| s[:transaction_name] == "PostsController#show" }[:histogram]).to eq({ "50" => 1 })
    end
  end
end
