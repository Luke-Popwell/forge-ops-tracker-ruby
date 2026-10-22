require "spec_helper"
require "net/http"
require "webrick"
require "socket"
require "forge_ops_tracker/integrations/net_http"

RSpec.describe ForgeOpsTracker::Integrations::NetHTTP::Timing do
  # A real local server, not a stubbed Net::HTTP#request: Timing wraps the real method via
  # Module#prepend and calls `super`, so the thing actually worth verifying is that a real request
  # still completes normally and returns the real response through the wrapper, the same "prepend
  # a module, don't replace the method" reasoning that needs a real round trip to actually prove.
  around do |example|
    server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc("/") { |_req, res| res.body = "ok" }
    server.mount_proc("/error") { |_req, res| res.status = 500; res.body = "boom" }
    server.mount_proc("/not_found") { |_req, res| res.status = 404 }
    server.mount_proc("/traceparent") { |req, res| res.body = req["traceparent"].to_s }
    thread = Thread.new { server.start }
    sleep 0.05 until server.status == :Running
    @port = server.config[:Port]
    example.run
  ensure
    server&.shutdown
    thread&.join
  end

  let(:configuration) do
    ForgeOpsTracker::Configuration.new.tap do |c|
      c.dsn = "https://key@tracker.example.com/api/v1/events"
      c.enabled_environments = %w[test]
      c.environment = "test"
      c.track_performance = true
      c.track_tracing = true
    end
  end
  let(:flusher) { instance_double(ForgeOpsTracker::PerformanceFlusher, record: nil) }
  let(:failure_buffer) { instance_double(ForgeOpsTracker::FailureEventBuffer, record: nil) }

  before do
    allow(ForgeOpsTracker).to receive(:configuration).and_return(configuration)
    allow(ForgeOpsTracker::Railtie).to receive(:performance_flusher).and_return(flusher)
    allow(ForgeOpsTracker::Railtie).to receive(:failure_event_buffer).and_return(failure_buffer)
    Net::HTTP.prepend(described_class) unless Net::HTTP.ancestors.include?(described_class)
  end

  after do
    Thread.current[:forge_ops_tracker_breadcrumbs] = nil
    Thread.current[:forge_ops_tracker_spans] = nil
    Thread.current[:forge_ops_tracker_request_context] = nil
  end

  it "still performs the real request and returns the real response" do
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/"))

    expect(response.body).to eq("ok")
  end

  it "records the method and host, kind: http" do
    Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/"))

    expect(flusher).to have_received(:record).with(transaction_name: "GET 127.0.0.1", duration_ms: kind_of(Numeric), kind: "http")
  end

  it "does not record when disabled" do
    configuration.track_performance = false

    Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/"))

    expect(flusher).not_to have_received(:record)
  end

  it "records an http breadcrumb with the method, host, status, and duration" do
    Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/"))

    entry = Thread.current[:forge_ops_tracker_breadcrumbs].all.first
    expect(entry[:category]).to eq("http")
    expect(entry[:message]).to eq("GET 127.0.0.1")
    expect(entry[:level]).to eq("info")
    expect(entry[:data][:status]).to eq(200)
    expect(entry[:data][:duration_ms]).to be_a(Numeric)
  end

  it "does not record a breadcrumb when track_breadcrumbs is off" do
    configuration.track_breadcrumbs = false

    Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/"))

    expect(Thread.current[:forge_ops_tracker_breadcrumbs]).to be_nil
  end

  it "records a dependency failure for a 5xx response" do
    Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/error"))

    expect(failure_buffer).to have_received(:record).with(kind: "dependency", transaction_name: "GET 127.0.0.1", error_class: nil, error_message: nil)
  end

  it "does not record a dependency failure for a 4xx response, only a warning-level breadcrumb" do
    Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/not_found"))

    expect(failure_buffer).not_to have_received(:record)
  end

  it "does not record a dependency failure for a successful response" do
    Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/"))

    expect(failure_buffer).not_to have_received(:record)
  end

  it "records a dependency failure, with the real error class/message, when the request itself raises" do
    # Net::HTTP.new(...).request(...), not Net::HTTP.start { |http| http.request(...) } or
    # Net::HTTP.get_response: confirmed directly (not assumed) that the latter two open the TCP
    # connection inside #start, *before* the block containing #request ever runs, so a
    # connection-refused failure there never reaches #request (and so never reaches this wrapper)
    # at all; see this integration's own top comment for that gap. Calling #request directly on a
    # never-started instance is different: Net::HTTP connects lazily, inside #request itself, on
    # first use, confirmed directly against a real connection-refused port, which is exactly why
    # this specific calling convention is the one that actually exercises the failure path below.
    closed_port_server = TCPServer.new("127.0.0.1", 0)
    closed_port = closed_port_server.addr[1]
    closed_port_server.close

    raised_error = nil
    begin
      Net::HTTP.new("127.0.0.1", closed_port).request(Net::HTTP::Get.new("/"))
    rescue StandardError => e
      raised_error = e
    end

    expect(raised_error).not_to be_nil
    expect(failure_buffer).to have_received(:record).with(kind: "dependency", transaction_name: "GET 127.0.0.1", error_class: raised_error.class.name, error_message: kind_of(String))
  end

  it "does not record a dependency failure when track_failures is off" do
    configuration.track_failures = false

    Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/error"))

    expect(failure_buffer).not_to have_received(:record)
  end

  it "records an http span onto the current request's SpanBuffer, parented onto whatever was open" do
    buffer = ForgeOpsTracker::SpanBuffer.new
    Thread.current[:forge_ops_tracker_spans] = buffer

    Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/"))

    span = buffer.spans.first
    expect(span[:name]).to eq("GET 127.0.0.1")
    expect(span[:kind]).to eq("http")
    expect(span[:parent_span_id]).to eq(buffer.root_span_id)
    expect(span[:duration_ms]).to be_a(Numeric)
    expect(span[:data]).to eq(status: 200)
  end

  it "does not record a span when there is no current request trace at all" do
    expect { Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/")) }.not_to raise_error
  end

  it "does not record a span when track_tracing is off" do
    configuration.track_tracing = false
    buffer = ForgeOpsTracker::SpanBuffer.new
    Thread.current[:forge_ops_tracker_spans] = buffer

    Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/"))

    expect(buffer.spans).to eq([])
  end

  describe "trace propagation" do
    let(:trace_id) { "4bf92f3577b34da6a3ce929d0e0e4736" }
    let(:state) { ForgeOpsTracker::RequestState.new(trace_id: trace_id) }

    def fetch_traceparent(request = Net::HTTP::Get.new("/traceparent"))
      Net::HTTP.start("127.0.0.1", @port) { |http| http.request(request) }.body
    end

    it "sends a W3C traceparent header continuing the current request's trace" do
      Thread.current[:forge_ops_tracker_request_context] = state

      expect(fetch_traceparent).to match(/\A00-#{trace_id}-[0-9a-f]{16}-01\z/)
    end

    it "uses the outbound http span's own span id as the header's parent id" do
      Thread.current[:forge_ops_tracker_request_context] = state
      buffer = ForgeOpsTracker::SpanBuffer.new(trace_id: trace_id)
      Thread.current[:forge_ops_tracker_spans] = buffer

      header = fetch_traceparent

      expect(header.split("-")[2]).to eq(buffer.spans.first[:span_id])
    end

    it "still propagates with track_tracing off, since the trace id links errors across services on its own" do
      configuration.track_tracing = false
      Thread.current[:forge_ops_tracker_request_context] = state

      expect(fetch_traceparent).to start_with("00-#{trace_id}-")
    end

    it "leaves a traceparent the caller already set alone" do
      Thread.current[:forge_ops_tracker_request_context] = state
      existing = "00-#{"b" * 32}-#{"c" * 16}-01"
      request = Net::HTTP::Get.new("/traceparent")
      request["traceparent"] = existing

      expect(fetch_traceparent(request)).to eq(existing)
    end

    it "sends nothing outside a request, with no trace to continue" do
      expect(fetch_traceparent).to eq("")
    end

    it "sends nothing when propagate_traces is off" do
      configuration.propagate_traces = false
      Thread.current[:forge_ops_tracker_request_context] = state

      expect(fetch_traceparent).to eq("")
    end

    it "sends nothing to a host outside trace_propagation_targets" do
      configuration.trace_propagation_targets = [ "internal.example" ]
      Thread.current[:forge_ops_tracker_request_context] = state

      expect(fetch_traceparent).to eq("")
    end

    it "sends it to a host that matches trace_propagation_targets" do
      configuration.trace_propagation_targets = [ /\A127\.0\.0\.1\z/ ]
      Thread.current[:forge_ops_tracker_request_context] = state

      expect(fetch_traceparent).to start_with("00-#{trace_id}-")
    end

    it "sends nothing when the gem isn't enabled" do
      configuration.dsn = nil
      Thread.current[:forge_ops_tracker_request_context] = state

      expect(fetch_traceparent).to eq("")
    end
  end
end
