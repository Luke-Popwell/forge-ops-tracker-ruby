require "spec_helper"
require "timeout"
require "tempfile"
require "rbconfig"

RSpec.describe ForgeOpsTracker::SessionFlusher do
  let(:configuration) do
    ForgeOpsTracker::Configuration.new.tap do |c|
      c.release = "1.2.3"
      c.environment = "production"
    end
  end

  describe "#record_session and #flush" do
    it "aggregates counts and delivers a snapshot, resetting after a successful flush" do
      delivered = Queue.new
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_session_checkin) { |payload| delivered << payload; true }

      flusher = described_class.new(configuration, client: client)
      flusher.record_session(crashed: false)
      flusher.record_session(crashed: true)
      flusher.record_session(crashed: false)
      flusher.flush

      payload = delivered.pop
      expect(payload[:sessions_count]).to eq(3)
      expect(payload[:crashed_sessions_count]).to eq(1)
      expect(payload[:release]).to eq("1.2.3")
      expect(payload[:environment]).to eq("production")

      # Nothing new was recorded since the successful flush above, so this one sends nothing.
      flusher.flush
      expect(delivered).to be_empty
    end

    it "does nothing on a flush with no sessions recorded" do
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_session_checkin)

      described_class.new(configuration, client: client).flush

      expect(client).not_to have_received(:deliver_session_checkin)
    end

    it "keeps the counts for the next flush instead of losing them when delivery fails" do
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_session_checkin).and_return(false)

      flusher = described_class.new(configuration, client: client)
      flusher.record_session(crashed: false)
      flusher.flush

      delivered_payload = nil
      allow(client).to receive(:deliver_session_checkin) { |payload| delivered_payload = payload; true }
      flusher.record_session(crashed: false)
      flusher.flush

      expect(delivered_payload[:sessions_count]).to eq(2)
    end

    it "drops a batch the server rejected instead of sending it again" do
      delivered = []
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_session_checkin) { |batch| delivered << batch.dup; :rejected }

      flusher = described_class.new(configuration, client: client)
      flusher.record_session(crashed: false)
      flusher.flush
      flusher.record_session(crashed: true)
      flusher.flush
      flusher.flush

      expect(delivered.map { |batch| batch[:sessions_count] }).to eq([ 1, 1 ])
    end

    it "keeps a batch through a failure that may pass, but drops it at the fifth flush in a row that failed" do
      delivered = []
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_session_checkin) { |batch| delivered << batch.dup; :failed }

      flusher = described_class.new(configuration, client: client)
      flusher.record_session(crashed: false)
      5.times { flusher.flush }
      flusher.flush

      # Sent on each of the five failing flushes, then gone: the sixth has nothing to send.
      expect(delivered.map { |batch| batch[:sessions_count] }).to eq([ 1, 1, 1, 1, 1 ])
    end

    it "starts counting failed flushes again after one that got through" do
      results = [ :failed, :failed, :failed, :failed, :delivered, :failed, :failed, :failed, :failed, :delivered ]
      delivered = []
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_session_checkin) { |batch| delivered << batch.dup; results.shift }

      flusher = described_class.new(configuration, client: client)
      flusher.record_session(crashed: false)
      5.times { flusher.flush }
      flusher.record_session(crashed: true)
      5.times { flusher.flush }

      expect(delivered.size).to eq(10)
      expect(results).to be_empty
    end
  end

  describe "background flushing" do
    it "flushes periodically on its own lazily-started background thread" do
      configuration.session_flush_interval = 0.05
      delivered = Queue.new
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver_session_checkin) { |payload| delivered << payload; true }

      flusher = described_class.new(configuration, client: client)
      flusher.record_session(crashed: false)

      expect(Timeout.timeout(1) { delivered.pop }[:sessions_count]).to eq(1)
    end

    it "recovers from the client raising instead of returning, without killing the thread" do
      configuration.session_flush_interval = 0.02
      # A signal per delivery attempt (success or raise), so the test can wait for the failing
      # first attempt to actually happen instead of guessing at a sleep long enough to cover it.
      attempts = Queue.new
      delivered = Queue.new
      client = instance_double(ForgeOpsTracker::Client)
      call_count = 0
      allow(client).to receive(:deliver_session_checkin) do |payload|
        call_count += 1
        attempts << true
        raise "boom" if call_count == 1

        delivered << payload
        true
      end

      flusher = described_class.new(configuration, client: client)
      flusher.record_session(crashed: false)
      Timeout.timeout(1) { attempts.pop } # the failing first attempt has now happened
      # Not reset by that failed attempt (see the "keeps the counts" example above), so this
      # second session joins the same still-pending window rather than starting a fresh one.
      flusher.record_session(crashed: false)

      expect(Timeout.timeout(1) { delivered.pop }[:sessions_count]).to eq(2)
    end
  end

  describe "at_exit" do
    it "flushes any pending counts on normal process exit, not just via an explicit #flush call" do
      output_file = Tempfile.new("session_flusher_at_exit")
      output_file.close

      script = <<~RUBY
        $LOAD_PATH.unshift(#{File.expand_path("../../lib", __dir__).inspect})
        require "forge_ops_tracker"

        configuration = ForgeOpsTracker::Configuration.new
        configuration.release = "1.0.0"

        client = Object.new
        def client.deliver_session_checkin(payload)
          File.write(#{output_file.path.inspect}, payload.to_json)
          true
        end

        ForgeOpsTracker::SessionFlusher.new(configuration, client: client).record_session(crashed: false)
      RUBY

      system(RbConfig.ruby, "-e", script, exception: true)

      expect(File.read(output_file.path)).to include("\"sessions_count\":1")
    ensure
      output_file&.unlink
    end
  end
end
