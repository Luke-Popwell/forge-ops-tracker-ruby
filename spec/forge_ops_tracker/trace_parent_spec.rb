require "spec_helper"

RSpec.describe ForgeOpsTracker::TraceParent do
  let(:trace_id) { "4bf92f3577b34da6a3ce929d0e0e4736" }
  let(:parent_id) { "00f067aa0ba902b7" }

  describe ".parse" do
    it "reads the trace id and parent span id out of a valid version-00 header" do
      expect(described_class.parse("00-#{trace_id}-#{parent_id}-01")).to eq(trace_id: trace_id, parent_span_id: parent_id)
    end

    it "accepts an unsampled header too: the flags never decide whether the trace is continued" do
      expect(described_class.parse("00-#{trace_id}-#{parent_id}-00")).to eq(trace_id: trace_id, parent_span_id: parent_id)
    end

    it "ignores surrounding whitespace" do
      expect(described_class.parse("  00-#{trace_id}-#{parent_id}-01 ")).to eq(trace_id: trace_id, parent_span_id: parent_id)
    end

    it "accepts a future version with extra trailing fields, the way the spec asks a version-00 parser to" do
      expect(described_class.parse("01-#{trace_id}-#{parent_id}-01-something-new")).to eq(trace_id: trace_id, parent_span_id: parent_id)
    end

    it "rejects extra trailing fields on version 00 itself" do
      expect(described_class.parse("00-#{trace_id}-#{parent_id}-01-extra")).to be_nil
    end

    it "rejects the reserved version ff" do
      expect(described_class.parse("ff-#{trace_id}-#{parent_id}-01")).to be_nil
    end

    it "rejects an all-zero trace id" do
      expect(described_class.parse("00-#{"0" * 32}-#{parent_id}-01")).to be_nil
    end

    it "rejects an all-zero parent id" do
      expect(described_class.parse("00-#{trace_id}-#{"0" * 16}-01")).to be_nil
    end

    it "rejects uppercase hex, which the spec doesn't allow" do
      expect(described_class.parse("00-#{trace_id.upcase}-#{parent_id}-01")).to be_nil
    end

    it "rejects malformed values" do
      [
        nil, "", "garbage", "00-#{trace_id}-#{parent_id}", "00-#{trace_id[0..30]}-#{parent_id}-01",
        "00-#{trace_id}-#{parent_id}-1", "00_#{trace_id}_#{parent_id}_01", "00-#{trace_id}-zzzzzzzzzzzzzzzz-01"
      ].each do |value|
        expect(described_class.parse(value)).to be_nil, "expected #{value.inspect} to be rejected"
      end
    end
  end

  describe ".build" do
    it "writes a version-00, sampled header" do
      expect(described_class.build(trace_id: trace_id, span_id: parent_id)).to eq("00-#{trace_id}-#{parent_id}-01")
    end

    it "round-trips through .parse" do
      header = described_class.build(trace_id: trace_id, span_id: parent_id)

      expect(described_class.parse(header)).to eq(trace_id: trace_id, parent_span_id: parent_id)
    end
  end

  it "generates 32-character lowercase hex trace ids and 16-character lowercase hex span ids" do
    expect(described_class.generate_trace_id).to match(/\A[0-9a-f]{32}\z/)
    expect(described_class.generate_span_id).to match(/\A[0-9a-f]{16}\z/)
  end
end
