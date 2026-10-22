require "spec_helper"

RSpec.describe ForgeOpsTracker::Middleware::RequestContext do
  let(:configuration) do
    ForgeOpsTracker::Configuration.new.tap do |c|
      c.dsn = "https://key@tracker.example.com/api/v1/events"
      c.enabled_environments = %w[production]
      c.environment = "production"
    end
  end
  let(:trace_id) { "4bf92f3577b34da6a3ce929d0e0e4736" }
  let(:parent_id) { "00f067aa0ba902b7" }

  after do
    Thread.current[:forge_ops_tracker_request_context] = nil
    Thread.current[:forge_ops_tracker_current_user] = nil
    Thread.current[:forge_ops_tracker_breadcrumbs] = nil
    Thread.current[:forge_ops_tracker_spans] = nil
  end

  it "publishes the request's RequestState for the duration of the call, then clears it" do
    seen_during_call = nil
    app = lambda do |_env|
      seen_during_call = described_class.current
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    response = middleware.call({})

    expect(response).to eq([ 200, {}, [ "ok" ] ])
    expect(seen_during_call).to be_a(ForgeOpsTracker::RequestState)
    expect(seen_during_call.trace_id).to match(/\A[0-9a-f]{32}\z/)
    expect(described_class.current).to be_nil
  end

  it "continues an incoming traceparent's trace, remembering the caller's span as the remote parent" do
    seen_during_call = nil
    app = lambda do |_env|
      seen_during_call = described_class.current
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    middleware.call("HTTP_TRACEPARENT" => "00-#{trace_id}-#{parent_id}-01")

    expect(seen_during_call.trace_id).to eq(trace_id)
    expect(seen_during_call.parent_span_id).to eq(parent_id)
  end

  it "gives each request its own trace id, not one shared across requests on the same thread" do
    trace_ids = []
    app = lambda do |_env|
      trace_ids << described_class.current.trace_id
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    middleware.call({})
    middleware.call({})

    expect(trace_ids.uniq.length).to eq(2)
  end

  it "still sets up a trace id with track_tracing off, since errors carry it too" do
    configuration.track_tracing = false
    seen_during_call = nil
    app = lambda do |_env|
      seen_during_call = described_class.current
      [ 200, {}, [ "ok" ] ]
    end

    described_class.new(app, configuration: configuration).call({})

    expect(seen_during_call).to be_a(ForgeOpsTracker::RequestState)
  end

  it "does not set anything up when the configuration itself isn't enabled" do
    configuration.dsn = nil
    seen_during_call = :unset
    app = lambda do |_env|
      seen_during_call = described_class.current
      [ 200, {}, [ "ok" ] ]
    end

    described_class.new(app, configuration: configuration).call({})

    expect(seen_during_call).to be_nil
  end

  describe "when the app raises" do
    it "re-raises the exact same exception, marks the request errored, and clears the thread-local" do
      env = {}
      original = ArgumentError.new("boom")
      middleware = described_class.new(->(_env) { raise original }, configuration: configuration)

      expect { middleware.call(env) }.to raise_error { |raised| expect(raised).to equal(original) }
      expect(ForgeOpsTracker::RequestState.for(env)).to be_errored
      expect(described_class.current).to be_nil
    end

    it "attaches a snapshot of the user, breadcrumbs, transaction name, endpoint, and trace id to the exception" do
      app = lambda do |_env|
        Thread.current[:forge_ops_tracker_current_user] = { id: 7 }
        buffer = ForgeOpsTracker::BreadcrumbBuffer.new(configuration)
        buffer.add(category: "custom", message: "charged card")
        Thread.current[:forge_ops_tracker_breadcrumbs] = buffer
        described_class.current.controller_started(controller: "CheckoutsController", action: "create", method: "POST")
        raise ArgumentError, "boom"
      end
      middleware = described_class.new(app, configuration: configuration)

      raised = begin
        middleware.call("HTTP_TRACEPARENT" => "00-#{trace_id}-#{parent_id}-01")
      rescue ArgumentError => e
        e
      end

      snapshot = described_class.snapshot_for(raised)
      expect(snapshot[:user]).to eq(id: 7)
      expect(snapshot[:breadcrumbs].map { |b| b[:message] }).to eq([ "charged card" ])
      expect(snapshot[:transaction_name]).to eq("CheckoutsController#create")
      expect(snapshot[:endpoint]).to eq("POST CheckoutsController#create")
      expect(snapshot[:trace_id]).to eq(trace_id)
    end

    it "catches non-StandardError exceptions too, still re-raising them" do
      env = {}
      middleware = described_class.new(->(_env) { raise Interrupt }, configuration: configuration)

      expect { middleware.call(env) }.to raise_error(Interrupt)
      expect(ForgeOpsTracker::RequestState.for(env)).to be_errored
    end

    it "never raises a FrozenError of its own for a frozen exception; the original still propagates" do
      frozen = ArgumentError.new("frozen boom").freeze
      middleware = described_class.new(->(_env) { raise frozen }, configuration: configuration)

      expect { middleware.call({}) }.to raise_error(ArgumentError, "frozen boom")
      expect(described_class.snapshot_for(frozen)).to be_nil
    end

    it "does not attach anything when the configuration itself isn't enabled" do
      configuration.dsn = nil
      middleware = described_class.new(->(_env) { raise ArgumentError, "boom" }, configuration: configuration)

      raised = begin
        middleware.call({})
      rescue ArgumentError => e
        e
      end

      expect(described_class.snapshot_for(raised)).to be_nil
    end
  end

  # The case this middleware exists for: Rails 8.1 reports an unhandled request exception from
  # ActionDispatch::Executor, outside every middleware this gem installs, so by the time
  # ErrorSubscriber#report runs, every one of them has already cleared its thread-local. Built in
  # the same order Railtie installs them (RequestContext innermost), then reported only once the
  # whole stack has unwound, the way the executor does it.
  describe "an unhandled error reported after the whole middleware stack has unwound" do
    let(:delivery_queue) { instance_double(ForgeOpsTracker::DeliveryQueue, push: true) }
    let(:span_queue) { instance_double(ForgeOpsTracker::SpanQueue, push: true) }
    let(:session_flusher) { instance_double(ForgeOpsTracker::SessionFlusher, record_session: nil) }
    let(:subscriber) do
      ForgeOpsTracker::ErrorSubscriber.new(configuration, delivery_queue: delivery_queue, event_builder: ForgeOpsTracker::EventBuilder.new(configuration))
    end

    before { allow(ForgeOpsTracker::Railtie).to receive(:span_queue).and_return(span_queue) }

    def build_stack(app)
      inner = described_class.new(app, configuration: configuration)
      inner = ForgeOpsTracker::Middleware::SpanTracing.new(inner, configuration: configuration)
      inner = ForgeOpsTracker::Middleware::BreadcrumbContext.new(inner, configuration: configuration)
      inner = ForgeOpsTracker::Middleware::UserContext.new(inner, configuration: configuration)
      ForgeOpsTracker::Middleware::SessionTracking.new(inner, configuration: configuration, flusher: session_flusher)
    end

    it "keeps its breadcrumbs, user, transaction name, endpoint, and trace id" do
      user = Struct.new(:id, :email).new(42, "alice@example.com")
      warden = Struct.new(:user).new(user)
      route = Struct.new(:route_uri_pattern).new("/checkout(.:format)")
      app = lambda do |_env|
        # What the start_processing.action_controller subscription does in a real app.
        described_class.current.controller_started(controller: "CheckoutsController", action: "create", method: "POST", request: route)
        ForgeOpsTracker.add_breadcrumb("charged card", category: "billing")
        raise ArgumentError, "card declined"
      end

      raised = begin
        build_stack(app).call("warden" => warden, "HTTP_TRACEPARENT" => "00-#{trace_id}-#{parent_id}-01")
      rescue ArgumentError => e
        e
      end

      # Every middleware's own ensure has run by now: nothing live is left to read.
      expect(Thread.current[:forge_ops_tracker_current_user]).to be_nil
      expect(Thread.current[:forge_ops_tracker_breadcrumbs]).to be_nil
      expect(described_class.current).to be_nil

      subscriber.report(raised, handled: false, severity: :error, source: "application.action_dispatch")

      expect(delivery_queue).to have_received(:push) do |payload|
        expect(payload[:exception_class]).to eq("ArgumentError")
        expect(payload[:user]).to eq(id: 42, email: "alice@example.com")
        expect(payload[:breadcrumbs].map { |b| b[:message] }).to eq([ "charged card" ])
        expect(payload[:transaction_name]).to eq("CheckoutsController#create")
        expect(payload[:endpoint]).to eq("POST /checkout")
        expect(payload[:trace_id]).to eq(trace_id)
      end
    end
  end
end
