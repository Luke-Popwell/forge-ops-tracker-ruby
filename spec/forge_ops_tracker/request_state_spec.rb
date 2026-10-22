require "spec_helper"

RSpec.describe ForgeOpsTracker::RequestState do
  let(:trace_id) { "4bf92f3577b34da6a3ce929d0e0e4736" }
  let(:parent_id) { "00f067aa0ba902b7" }

  describe ".for" do
    it "continues the trace from an incoming traceparent header, remembering the caller's span as the remote parent" do
      state = described_class.for("HTTP_TRACEPARENT" => "00-#{trace_id}-#{parent_id}-01")

      expect(state.trace_id).to eq(trace_id)
      expect(state.parent_span_id).to eq(parent_id)
    end

    it "starts a fresh trace, with no remote parent, when there's no header" do
      state = described_class.for({})

      expect(state.trace_id).to match(/\A[0-9a-f]{32}\z/)
      expect(state.parent_span_id).to be_nil
    end

    it "starts a fresh trace rather than trusting a malformed header" do
      state = described_class.for("HTTP_TRACEPARENT" => "00-#{"0" * 32}-#{parent_id}-01")

      expect(state.trace_id).not_to eq("0" * 32)
      expect(state.trace_id).to match(/\A[0-9a-f]{32}\z/)
      expect(state.parent_span_id).to be_nil
    end

    it "hands back the same instance for the same env, so every middleware in one request shares it" do
      env = {}

      expect(described_class.for(env)).to equal(described_class.for(env))
    end

    it "gives two different requests two different trace ids" do
      expect(described_class.for({}).trace_id).not_to eq(described_class.for({}).trace_id)
    end
  end

  describe "#controller_started" do
    it "names the transaction and the endpoint from a start_processing.action_controller payload" do
      request = Struct.new(:route_uri_pattern).new("/orders/:id(.:format)")
      state = described_class.new

      state.controller_started(controller: "OrdersController", action: "show", method: "GET", request: request)

      expect(state.transaction_name).to eq("OrdersController#show")
      expect(state.endpoint).to eq("GET /orders/:id")
    end
  end

  it "starts out not errored, and stays errored once marked" do
    state = described_class.new

    expect(state).not_to be_errored
    state.mark_errored!
    expect(state).to be_errored
  end
end
