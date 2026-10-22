require "spec_helper"
require "timeout"

RSpec.describe ForgeOpsTracker::InfrastructureMetricBuffer do
  let(:configuration) { ForgeOpsTracker::Configuration.new }

  describe "#record and #flush" do
    it "buffers individual readings as-is and delivers them as one batch" do
      delivered = Queue.new
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_infrastructure_metrics) { |entries| delivered << entries; true }

      buffer = described_class.new(configuration, client: client)
      buffer.record(metric_name: "cpu_percent", value: 42.5, hostname: "web-1")
      buffer.record(metric_name: "memory_used_mb", value: 512.0, hostname: "web-1")
      buffer.flush

      entries = delivered.pop
      expect(entries.size).to eq(2)
      cpu_entry = entries.find { |e| e[:metric_name] == "cpu_percent" }
      expect(cpu_entry).to include(value: 42.5, hostname: "web-1")

      buffer.flush
      expect(delivered).to be_empty
    end

    it "does nothing on a flush with nothing recorded" do
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_infrastructure_metrics)

      described_class.new(configuration, client: client).flush

      expect(client).not_to have_received(:deliver_infrastructure_metrics)
    end

    it "keeps every reading for the next flush instead of losing them when delivery fails" do
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_infrastructure_metrics).and_return(false)

      buffer = described_class.new(configuration, client: client)
      buffer.record(metric_name: "cpu_percent", value: 10.0, hostname: "web-1")
      buffer.flush

      delivered_entries = nil
      allow(client).to receive(:deliver_infrastructure_metrics) { |entries| delivered_entries = entries; true }
      buffer.record(metric_name: "cpu_percent", value: 20.0, hostname: "web-1")
      buffer.flush

      expect(delivered_entries.size).to eq(2)
    end

    it "drops a batch the server rejected instead of sending it again" do
      delivered = []
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_infrastructure_metrics) { |batch| delivered << batch.dup; :rejected }

      buffer = described_class.new(configuration, client: client)
      buffer.record(metric_name: "cpu", value: 1.0, hostname: "web-1")
      buffer.flush
      buffer.record(metric_name: "memory", value: 2.0, hostname: "web-1")
      buffer.flush
      buffer.flush

      expect(delivered.map { |batch| batch.size }).to eq([ 1, 1 ])
    end

    it "keeps a batch through a failure that may pass, but drops it at the fifth flush in a row that failed" do
      delivered = []
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_infrastructure_metrics) { |batch| delivered << batch.dup; :failed }

      buffer = described_class.new(configuration, client: client)
      buffer.record(metric_name: "cpu", value: 1.0, hostname: "web-1")
      5.times { buffer.flush }
      buffer.flush

      # Sent on each of the five failing flushes, then gone: the sixth has nothing to send.
      expect(delivered.map { |batch| batch.size }).to eq([ 1, 1, 1, 1, 1 ])
    end

    it "starts counting failed flushes again after one that got through" do
      results = [ :failed, :failed, :failed, :failed, :delivered, :failed, :failed, :failed, :failed, :delivered ]
      delivered = []
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_infrastructure_metrics) { |batch| delivered << batch.dup; results.shift }

      buffer = described_class.new(configuration, client: client)
      buffer.record(metric_name: "cpu", value: 1.0, hostname: "web-1")
      5.times { buffer.flush }
      buffer.record(metric_name: "memory", value: 2.0, hostname: "web-1")
      5.times { buffer.flush }

      expect(delivered.size).to eq(10)
      expect(results).to be_empty
    end
  end

  describe "background flushing" do
    it "flushes periodically on its own lazily-started background thread" do
      configuration.infrastructure_metric_flush_interval = 0.05
      delivered = Queue.new
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_infrastructure_metrics) { |entries| delivered << entries; true }

      buffer = described_class.new(configuration, client: client)
      buffer.record(metric_name: "cpu_percent", value: 10.0, hostname: "web-1")

      expect(Timeout.timeout(1) { delivered.pop }.size).to eq(1)
    end
  end

  describe "in-flight, cap and non-finite handling" do
    let(:configuration) { ForgeOpsTracker::Configuration.new.tap { |c| c.environment = "production" } }

    it "keeps an entry recorded while delivery is in flight for the next flush" do
      buffer = nil
      delivered = []
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_infrastructure_metrics) do |entries|
        delivered << entries.map { |e| e[:metric_name] }
        buffer.record(metric_name: "during", value: 0.5, hostname: "web-1") if delivered.size == 1
        true
      end

      buffer = described_class.new(configuration, client: client)
      buffer.record(metric_name: "first", value: 0.5, hostname: "web-1")
      buffer.flush
      buffer.flush

      expect(delivered).to eq([ [ "first" ], [ "during" ] ])
    end

    it "caps the buffer and drops further entries until a flush succeeds" do
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_infrastructure_metrics).and_return(false)
      buffer = described_class.new(configuration, client: client)

      accepted = (described_class::MAX_ENTRIES + 50).times.count { buffer.record(metric_name: "cpu", value: 0.5, hostname: "web-1") }

      expect(accepted).to eq(described_class::MAX_ENTRIES)
      # Nothing may be left for the at_exit flush to hand to a double after the example ends.
      buffer.instance_variable_set(:@entries, [])
    end

    it "drops a NaN, infinite or non-numeric value so it cannot poison a batch" do
      client = instance_double(ForgeOpsTracker::Client)
      buffer = described_class.new(configuration, client: client)

      expect(buffer.record(metric_name: "a", value: Float::NAN, hostname: 'h')).to be(false)
      expect(buffer.record(metric_name: "b", value: Float::INFINITY, hostname: 'h')).to be(false)
      expect(buffer.record(metric_name: "c", value: "12", hostname: 'h')).to be(false)
    end
  end
end
