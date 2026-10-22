require "spec_helper"
require "timeout"

RSpec.describe ForgeOpsTracker::FailureEventBuffer do
  let(:configuration) do
    ForgeOpsTracker::Configuration.new.tap do |c|
      c.release = "1.2.3"
      c.environment = "production"
    end
  end

  describe "#record and #flush" do
    it "buffers individual entries as-is and delivers them as one batch" do
      delivered = Queue.new
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_failure_events) { |entries| delivered << entries; true }

      buffer = described_class.new(configuration, client: client)
      buffer.record(kind: "job", transaction_name: "ChargeSubscriptionJob", error_class: "Stripe::CardError", error_message: "card was declined")
      buffer.record(kind: "dependency", transaction_name: "POST api.stripe.com")
      buffer.flush

      entries = delivered.pop
      expect(entries.size).to eq(2)
      job_entry = entries.find { |e| e[:kind] == "job" }
      expect(job_entry).to include(transaction_name: "ChargeSubscriptionJob", error_class: "Stripe::CardError",
        error_message: "card was declined", release: "1.2.3", environment: "production")

      # Nothing new was recorded since the successful flush above, so this one sends nothing.
      buffer.flush
      expect(delivered).to be_empty
    end

    it "does nothing on a flush with nothing recorded" do
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_failure_events)

      described_class.new(configuration, client: client).flush

      expect(client).not_to have_received(:deliver_failure_events)
    end

    it "keeps every entry for the next flush instead of losing them when delivery fails" do
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_failure_events).and_return(false)

      buffer = described_class.new(configuration, client: client)
      buffer.record(kind: "job", transaction_name: "ChargeSubscriptionJob")
      buffer.flush

      delivered_entries = nil
      allow(client).to receive(:deliver_failure_events) { |entries| delivered_entries = entries; true }
      buffer.record(kind: "job", transaction_name: "ChargeSubscriptionJob")
      buffer.flush

      expect(delivered_entries.size).to eq(2)
    end

    it "drops a batch the server rejected instead of sending it again" do
      delivered = []
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_failure_events) { |batch| delivered << batch.dup; :rejected }

      buffer = described_class.new(configuration, client: client)
      buffer.record(kind: "job", transaction_name: "ChargeSubscriptionJob")
      buffer.flush
      buffer.record(kind: "dependency", transaction_name: "POST api.stripe.com")
      buffer.flush
      buffer.flush

      expect(delivered.map { |batch| batch.size }).to eq([ 1, 1 ])
    end

    it "keeps a batch through a failure that may pass, but drops it at the fifth flush in a row that failed" do
      delivered = []
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_failure_events) { |batch| delivered << batch.dup; :failed }

      buffer = described_class.new(configuration, client: client)
      buffer.record(kind: "job", transaction_name: "ChargeSubscriptionJob")
      5.times { buffer.flush }
      buffer.flush

      # Sent on each of the five failing flushes, then gone: the sixth has nothing to send.
      expect(delivered.map { |batch| batch.size }).to eq([ 1, 1, 1, 1, 1 ])
    end

    it "starts counting failed flushes again after one that got through" do
      results = [ :failed, :failed, :failed, :failed, :delivered, :failed, :failed, :failed, :failed, :delivered ]
      delivered = []
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_failure_events) { |batch| delivered << batch.dup; results.shift }

      buffer = described_class.new(configuration, client: client)
      buffer.record(kind: "job", transaction_name: "ChargeSubscriptionJob")
      5.times { buffer.flush }
      buffer.record(kind: "dependency", transaction_name: "POST api.stripe.com")
      5.times { buffer.flush }

      expect(delivered.size).to eq(10)
      expect(results).to be_empty
    end
  end

  describe "cap and in-flight handling" do
    it "caps the buffer and drops further entries until a flush lets go of them" do
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_failure_events).and_return(:rejected)
      buffer = described_class.new(configuration, client: client)

      accepted = (described_class::MAX_ENTRIES + 50).times.count { buffer.record(kind: "job", transaction_name: "J") }
      expect(accepted).to eq(described_class::MAX_ENTRIES)

      buffer.flush
      expect(buffer.record(kind: "job", transaction_name: "J")).to be_truthy
      buffer.flush
    end

    it "keeps an entry recorded while delivery is in flight for the next flush" do
      buffer = nil
      delivered = []
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_failure_events) do |entries|
        delivered << entries.map { |e| e[:transaction_name] }
        buffer.record(kind: "job", transaction_name: "during") if delivered.size == 1
        true
      end

      buffer = described_class.new(configuration, client: client)
      buffer.record(kind: "job", transaction_name: "first")
      buffer.flush
      buffer.flush

      expect(delivered).to eq([ [ "first" ], [ "during" ] ])
    end
  end

  describe "background flushing" do
    it "flushes periodically on its own lazily-started background thread" do
      configuration.failure_event_flush_interval = 0.05
      delivered = Queue.new
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_failure_events) { |entries| delivered << entries; true }

      buffer = described_class.new(configuration, client: client)
      buffer.record(kind: "job", transaction_name: "ChargeSubscriptionJob")

      expect(Timeout.timeout(1) { delivered.pop }.size).to eq(1)
    end
  end
end
