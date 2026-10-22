require "spec_helper"

RSpec.describe ForgeOpsTracker::Middleware::SpanTracing do
  let(:configuration) do
    ForgeOpsTracker::Configuration.new.tap do |c|
      c.dsn = "https://key@tracker.example.com/api/v1/events"
      c.enabled_environments = %w[production]
      c.environment = "production"
      c.track_tracing = true
      c.trace_capture_threshold_ms = 1_000
    end
  end
  let(:span_queue) { instance_double(ForgeOpsTracker::SpanQueue, push: true) }

  before { allow(ForgeOpsTracker::Railtie).to receive(:span_queue).and_return(span_queue) }
  after { Thread.current[:forge_ops_tracker_spans] = nil }

  it "gives the request a fresh SpanBuffer for the duration of the call, then clears it" do
    seen_during_call = nil
    app = lambda do |_env|
      seen_during_call = Thread.current[:forge_ops_tracker_spans]
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    middleware.call({})

    expect(seen_during_call).to be_a(ForgeOpsTracker::SpanBuffer)
    expect(Thread.current[:forge_ops_tracker_spans]).to be_nil
  end

  it "gives each call its own buffer, not one shared across requests on the same thread" do
    buffers = []
    app = lambda do |_env|
      buffers << Thread.current[:forge_ops_tracker_spans]
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    middleware.call({})
    middleware.call({})

    expect(buffers[0]).not_to equal(buffers[1])
  end

  it "clears the buffer even when the app raises" do
    app = ->(_env) { raise ArgumentError, "boom" }
    middleware = described_class.new(app, configuration: configuration)

    expect { middleware.call({}) }.to raise_error(ArgumentError, "boom")
    expect(Thread.current[:forge_ops_tracker_spans]).to be_nil
  end

  it "sends the trace once the root span's duration meets the threshold" do
    app = lambda do |_env|
      Thread.current[:forge_ops_tracker_spans].record(
        span_id: Thread.current[:forge_ops_tracker_spans].root_span_id, name: "Controller#action", kind: "controller",
        started_at: Time.now.utc, duration_ms: 1_500.0, root: true
      )
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    middleware.call({})

    expect(span_queue).to have_received(:push).with(trace_id: kind_of(String), spans: kind_of(Array))
  end

  it "never sends the trace when the root span's duration is under the threshold" do
    app = lambda do |_env|
      Thread.current[:forge_ops_tracker_spans].record(
        span_id: Thread.current[:forge_ops_tracker_spans].root_span_id, name: "Controller#action", kind: "controller",
        started_at: Time.now.utc, duration_ms: 500.0, root: true
      )
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    middleware.call({})

    expect(span_queue).not_to have_received(:push)
  end

  it "never sends the trace when the root span was never recorded at all" do
    app = ->(_env) { [ 200, {}, [ "ok" ] ] }
    middleware = described_class.new(app, configuration: configuration)

    middleware.call({})

    expect(span_queue).not_to have_received(:push)
  end

  describe "trace identity" do
    let(:trace_id) { "4bf92f3577b34da6a3ce929d0e0e4736" }
    let(:parent_id) { "00f067aa0ba902b7" }

    it "uses the request's own RequestState trace id, the same one an error event from this request carries" do
      env = {}
      seen_buffer = nil
      app = lambda do |_env|
        seen_buffer = Thread.current[:forge_ops_tracker_spans]
        [ 200, {}, [ "ok" ] ]
      end

      described_class.new(app, configuration: configuration).call(env)

      expect(seen_buffer.trace_id).to eq(ForgeOpsTracker::RequestState.for(env).trace_id)
      expect(seen_buffer.parent_span_id).to be_nil
    end

    it "continues an incoming traceparent's trace, with the caller's span as the root span's parent" do
      app = lambda do |_env|
        buffer = Thread.current[:forge_ops_tracker_spans]
        buffer.pop
        buffer.record(span_id: buffer.root_span_id, name: "Controller#action", kind: "controller",
          started_at: Time.now.utc, duration_ms: 1_500.0, root: true)
        [ 200, {}, [ "ok" ] ]
      end

      described_class.new(app, configuration: configuration).call("HTTP_TRACEPARENT" => "00-#{trace_id}-#{parent_id}-01")

      expect(span_queue).to have_received(:push) do |**sent|
        expect(sent[:trace_id]).to eq(trace_id)
        expect(sent[:spans].first[:parent_span_id]).to eq(parent_id)
      end
    end

    it "shares one RequestState with RequestContext nested inside it, so both see the same trace id" do
      seen = {}
      app = lambda do |_env|
        seen[:context] = ForgeOpsTracker::Middleware::RequestContext.current.trace_id
        seen[:spans] = Thread.current[:forge_ops_tracker_spans].trace_id
        [ 200, {}, [ "ok" ] ]
      end
      inner = ForgeOpsTracker::Middleware::RequestContext.new(app, configuration: configuration)

      described_class.new(inner, configuration: configuration).call({})

      expect(seen[:spans]).to eq(seen[:context])
    end
  end

  describe "an errored request" do
    after { Thread.current[:forge_ops_tracker_request_context] = nil }

    def record_fast_root
      buffer = Thread.current[:forge_ops_tracker_spans]
      buffer.record(span_id: buffer.root_span_id, name: "Controller#action", kind: "controller",
        started_at: Time.now.utc, duration_ms: 20.0, root: true)
    end

    it "sends the trace however fast it was, when an unhandled exception passed through RequestContext" do
      app = lambda do |_env|
        record_fast_root
        raise ArgumentError, "boom"
      end
      inner = ForgeOpsTracker::Middleware::RequestContext.new(app, configuration: configuration)

      expect { described_class.new(inner, configuration: configuration).call({}) }.to raise_error(ArgumentError)

      expect(span_queue).to have_received(:push).with(trace_id: kind_of(String), spans: kind_of(Array))
    end

    it "sends the trace however fast it was, when a handled error was reported during the request" do
      subscriber = ForgeOpsTracker::ErrorSubscriber.new(
        configuration, delivery_queue: instance_double(ForgeOpsTracker::DeliveryQueue, push: true),
        event_builder: ForgeOpsTracker::EventBuilder.new(configuration)
      )
      app = lambda do |_env|
        subscriber.report(ArgumentError.new("handled"), handled: true)
        record_fast_root
        [ 200, {}, [ "ok" ] ]
      end
      inner = ForgeOpsTracker::Middleware::RequestContext.new(app, configuration: configuration)

      described_class.new(inner, configuration: configuration).call({})

      expect(span_queue).to have_received(:push).with(trace_id: kind_of(String), spans: kind_of(Array))
    end

    it "does not send an errored request's trace when its root span was never recorded" do
      inner = ForgeOpsTracker::Middleware::RequestContext.new(->(_env) { raise ArgumentError, "boom" }, configuration: configuration)

      expect { described_class.new(inner, configuration: configuration).call({}) }.to raise_error(ArgumentError)

      expect(span_queue).not_to have_received(:push)
    end

    it "still never sends a fast, successful request's trace" do
      app = lambda do |_env|
        record_fast_root
        [ 200, {}, [ "ok" ] ]
      end
      inner = ForgeOpsTracker::Middleware::RequestContext.new(app, configuration: configuration)

      described_class.new(inner, configuration: configuration).call({})

      expect(span_queue).not_to have_received(:push)
    end
  end

  it "does not set up a buffer at all when track_tracing is off" do
    configuration.track_tracing = false
    seen_during_call = :unset
    app = lambda do |_env|
      seen_during_call = Thread.current[:forge_ops_tracker_spans]
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    middleware.call({})

    expect(seen_during_call).to be_nil
  end

  it "does not set up a buffer when the configuration itself isn't enabled" do
    configuration.dsn = nil
    seen_during_call = :unset
    app = lambda do |_env|
      seen_during_call = Thread.current[:forge_ops_tracker_spans]
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    middleware.call({})

    expect(seen_during_call).to be_nil
  end
end
