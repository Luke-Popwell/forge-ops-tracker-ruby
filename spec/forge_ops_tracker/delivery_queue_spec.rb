require "spec_helper"
require "timeout"
require "tempfile"

RSpec.describe ForgeOpsTracker::DeliveryQueue do
  let(:configuration) { ForgeOpsTracker::Configuration.new.tap { |c| c.queue_size = 1 } }

  it "delivers a pushed payload via the client on its background worker thread" do
    delivered = Queue.new
    client = instance_double(ForgeOpsTracker::Client)
    allow(client).to receive(:deliver) { |payload| delivered << payload }

    queue = described_class.new(configuration, client: client)
    queue.push(exception_class: "RuntimeError")

    expect(Timeout.timeout(1) { delivered.pop }).to eq(exception_class: "RuntimeError")
  end

  it "drops a payload without blocking when the queue is already full" do
    queue = described_class.new(configuration, client: instance_double(ForgeOpsTracker::Client))
    # Prevent the background worker from draining the queue, so capacity
    # stays exactly at queue_size (1) for a deterministic full-queue test.
    allow(queue).to receive(:ensure_worker_started)

    expect(queue.push(n: 1)).to be true
    expect(Timeout.timeout(1) { queue.push(n: 2) }).to be false
  end

  it "recovers from the client raising instead of returning" do
    # A larger queue than the other examples, so both pushes below can be
    # enqueued regardless of exactly when the worker thread gets scheduled.
    roomy_configuration = ForgeOpsTracker::Configuration.new.tap { |c| c.queue_size = 10 }
    delivered = Queue.new
    client = instance_double(ForgeOpsTracker::Client)
    call_count = 0
    allow(client).to receive(:deliver) do |payload|
      call_count += 1
      raise "boom" if call_count == 1

      delivered << payload
    end

    queue = described_class.new(roomy_configuration, client: client)
    queue.push(n: 1) # raises inside the worker loop; must not kill the thread
    queue.push(n: 2)

    expect(Timeout.timeout(1) { delivered.pop }).to eq(n: 2)
  end

  it "sends a payload once, and says why it was dropped, whatever the client answers" do
    logged = Queue.new
    logger = Object.new
    logger.define_singleton_method(:debug) { |&message| logged << message.call }
    roomy_configuration = ForgeOpsTracker::Configuration.new.tap { |c| c.queue_size = 10; c.logger = logger }
    answers = [ :rejected, :failed, :delivered ]
    client = instance_double(ForgeOpsTracker::Client)
    allow(client).to receive(:deliver) { answers.shift }

    queue = described_class.new(roomy_configuration, client: client)
    3.times { |n| queue.push(n: n) }

    expect(Timeout.timeout(1) { logged.pop }).to include("the server rejected it")
    expect(Timeout.timeout(1) { logged.pop }).to include("delivery failed")
    Timeout.timeout(1) { sleep 0.01 until answers.empty? }
    expect(client).to have_received(:deliver).exactly(3).times
    expect(logged).to be_empty
  end

  describe "on process exit" do
    it "sends what's still queued before the process ends" do
      out = Tempfile.new("delivered")
      script = <<~RUBY
        require "forge_ops_tracker"
        client = Object.new
        def client.deliver(payload) = File.write(#{out.path.inspect}, payload[:message], mode: "a")
        queue = ForgeOpsTracker::DeliveryQueue.new(ForgeOpsTracker::Configuration.new, client: client)
        # Hold the worker back, the way a process exiting right after reporting outruns it.
        queue.define_singleton_method(:run) { sleep }
        queue.push(message: "reported just before exit")
      RUBY

      system(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script, exception: true)

      expect(File.read(out.path)).to eq("reported just before exit")
    end

    it "gives up at the timeout rather than holding the process open" do
      client = instance_double(ForgeOpsTracker::Client)
      allow(client).to receive(:deliver) { sleep 0.5 }
      queue = described_class.new(ForgeOpsTracker::Configuration.new, client: client)
      allow(queue).to receive(:ensure_worker_started)
      3.times { |n| queue.push(n: n) }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      queue.drain(timeout: 0.2)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.0
    end

    it "waits for nothing when nothing was ever reported" do
      queue = described_class.new(ForgeOpsTracker::Configuration.new, client: instance_double(ForgeOpsTracker::Client))

      expect { Timeout.timeout(0.1) { queue.drain } }.not_to raise_error
    end
  end
end
