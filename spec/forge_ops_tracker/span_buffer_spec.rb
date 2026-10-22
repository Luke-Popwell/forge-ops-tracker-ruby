require "spec_helper"

RSpec.describe ForgeOpsTracker::SpanBuffer do
  subject(:buffer) { described_class.new }

  it "generates a fresh trace_id and root_span_id, with the root already on the stack" do
    expect(buffer.trace_id).to be_a(String)
    expect(buffer.root_span_id).to be_a(String)
    expect(buffer.current_parent_id).to eq(buffer.root_span_id)
  end

  it "gives two different buffers different trace_ids and root_span_ids" do
    other = described_class.new

    expect(other.trace_id).not_to eq(buffer.trace_id)
    expect(other.root_span_id).not_to eq(buffer.root_span_id)
  end

  it "uses a trace_id and remote parent span id handed to it, rather than generating its own" do
    buffer = described_class.new(trace_id: "4bf92f3577b34da6a3ce929d0e0e4736", parent_span_id: "00f067aa0ba902b7")

    expect(buffer.trace_id).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
    expect(buffer.parent_span_id).to eq("00f067aa0ba902b7")
  end

  describe "#record" do
    it "parents a plain (non-root) span onto whatever's currently on top of the stack" do
      buffer.record(span_id: "s1", name: "SELECT users", kind: "database", started_at: Time.now.utc, duration_ms: 12.0)

      expect(buffer.spans.first[:parent_span_id]).to eq(buffer.root_span_id)
    end

    it "parents a span onto a manually pushed span, not the root, while that span is open" do
      buffer.push("service-1")
      buffer.record(span_id: "s1", name: "SELECT users", kind: "database", started_at: Time.now.utc, duration_ms: 12.0)

      expect(buffer.spans.first[:parent_span_id]).to eq("service-1")
    end

    it "reparents onto the root again once a manually pushed span is popped" do
      buffer.push("service-1")
      buffer.pop
      buffer.record(span_id: "s1", name: "SELECT users", kind: "database", started_at: Time.now.utc, duration_ms: 12.0)

      expect(buffer.spans.first[:parent_span_id]).to eq(buffer.root_span_id)
    end

    it "forces parent_span_id nil for a root: true span regardless of the stack" do
      buffer.record(span_id: buffer.root_span_id, name: "CheckoutController#create", kind: "controller",
        started_at: Time.now.utc, duration_ms: 1800.0, root: true)

      expect(buffer.spans.first[:parent_span_id]).to be_nil
    end

    it "parents a root: true span onto the incoming remote parent span, when the request continued a trace" do
      buffer = described_class.new(trace_id: "4bf92f3577b34da6a3ce929d0e0e4736", parent_span_id: "00f067aa0ba902b7")
      buffer.pop
      buffer.record(span_id: buffer.root_span_id, name: "CheckoutController#create", kind: "controller",
        started_at: Time.now.utc, duration_ms: 1800.0, root: true)

      expect(buffer.spans.first[:parent_span_id]).to eq("00f067aa0ba902b7")
    end

    it "still parents a non-root span onto the stack, never the remote parent" do
      buffer = described_class.new(parent_span_id: "00f067aa0ba902b7")
      buffer.record(span_id: "s1", name: "SELECT users", kind: "database", started_at: Time.now.utc, duration_ms: 12.0)

      expect(buffer.spans.first[:parent_span_id]).to eq(buffer.root_span_id)
    end

    it "serializes started_at as an ISO8601 string with millisecond precision" do
      time = Time.utc(2026, 1, 1, 10, 0, 0.123)
      buffer.record(span_id: "s1", name: "SELECT users", kind: "database", started_at: time, duration_ms: 12.0)

      expect(buffer.spans.first[:started_at]).to eq(time.iso8601(3))
    end

    it "carries the data hash through unchanged" do
      buffer.record(span_id: "s1", name: "GET api.stripe.com", kind: "http", started_at: Time.now.utc, duration_ms: 200.0, data: { status: 200 })

      expect(buffer.spans.first[:data]).to eq(status: 200)
    end
  end

  describe "#slow?" do
    it "is false before any root span has been recorded" do
      expect(buffer.slow?(1_000)).to be_falsey
    end

    it "is true once the recorded root span's duration meets the threshold" do
      buffer.record(span_id: buffer.root_span_id, name: "Controller#action", kind: "controller",
        started_at: Time.now.utc, duration_ms: 1_500.0, root: true)

      expect(buffer.slow?(1_000)).to be true
    end

    it "is false when the recorded root span's duration is under the threshold" do
      buffer.record(span_id: buffer.root_span_id, name: "Controller#action", kind: "controller",
        started_at: Time.now.utc, duration_ms: 500.0, root: true)

      expect(buffer.slow?(1_000)).to be false
    end
  end

  describe "#root_recorded?" do
    it "is false until the root span is recorded, then true" do
      expect(buffer.root_recorded?).to be false

      buffer.record(span_id: buffer.root_span_id, name: "Controller#action", kind: "controller",
        started_at: Time.now.utc, duration_ms: 5.0, root: true)

      expect(buffer.root_recorded?).to be true
    end

    it "stays false when only non-root spans were recorded" do
      buffer.record(span_id: "s1", name: "SELECT users", kind: "database", started_at: Time.now.utc, duration_ms: 12.0)

      expect(buffer.root_recorded?).to be false
    end
  end
end
