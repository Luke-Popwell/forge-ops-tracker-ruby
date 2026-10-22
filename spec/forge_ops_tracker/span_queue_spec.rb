require "spec_helper"
require "timeout"

RSpec.describe ForgeOpsTracker::SpanQueue do
  let(:configuration) { ForgeOpsTracker::Configuration.new.tap { |c| c.queue_size = 1 } }

  it "delivers a pushed trace via the client on its background worker thread" do
    delivered = Queue.new
    client = instance_double(ForgeOpsTracker::Client)
    allow(client).to receive(:deliver_spans) { |trace_id:, spans:| delivered << { trace_id: trace_id, spans: spans } }

    queue = described_class.new(configuration, client: client)
    queue.push(trace_id: "abc123", spans: [ { span_id: "s1" } ])

    result = Timeout.timeout(1) { delivered.pop }
    expect(result).to eq(trace_id: "abc123", spans: [ { span_id: "s1" } ])
  end

  it "drops a trace without blocking when the queue is already full" do
    queue = described_class.new(configuration, client: instance_double(ForgeOpsTracker::Client))
    allow(queue).to receive(:ensure_worker_started)

    expect(queue.push(trace_id: "t1", spans: [])).to be true
    expect(Timeout.timeout(1) { queue.push(trace_id: "t2", spans: []) }).to be false
  end

  it "recovers from the client raising instead of returning" do
    roomy_configuration = ForgeOpsTracker::Configuration.new.tap { |c| c.queue_size = 10 }
    delivered = Queue.new
    client = instance_double(ForgeOpsTracker::Client)
    call_count = 0
    allow(client).to receive(:deliver_spans) do |trace_id:, spans:|
      call_count += 1
      raise "boom" if call_count == 1

      delivered << trace_id
    end

    queue = described_class.new(roomy_configuration, client: client)
    queue.push(trace_id: "t1", spans: []) # raises inside the worker loop; must not kill the thread
    queue.push(trace_id: "t2", spans: [])

    expect(Timeout.timeout(1) { delivered.pop }).to eq("t2")
  end
end
