require "spec_helper"

RSpec.describe ForgeOpsTracker::Middleware::BreadcrumbContext do
  let(:configuration) do
    ForgeOpsTracker::Configuration.new.tap do |c|
      c.dsn = "https://key@tracker.example.com/api/v1/events"
      c.enabled_environments = %w[production]
      c.environment = "production"
    end
  end

  after { Thread.current[:forge_ops_tracker_breadcrumbs] = nil }

  it "gives the request a fresh buffer for the duration of the call, then clears it" do
    seen_during_call = nil
    app = lambda do |_env|
      seen_during_call = Thread.current[:forge_ops_tracker_breadcrumbs]
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    response = middleware.call({})

    expect(response).to eq([ 200, {}, [ "ok" ] ])
    expect(seen_during_call).to be_a(ForgeOpsTracker::BreadcrumbBuffer)
    expect(Thread.current[:forge_ops_tracker_breadcrumbs]).to be_nil
  end

  it "gives each call its own buffer, not one shared across requests on the same thread" do
    buffers = []
    app = lambda do |_env|
      buffers << Thread.current[:forge_ops_tracker_breadcrumbs]
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
    expect(Thread.current[:forge_ops_tracker_breadcrumbs]).to be_nil
  end

  it "does not set up a buffer at all when track_breadcrumbs is off" do
    configuration.track_breadcrumbs = false
    seen_during_call = :unset
    app = lambda do |_env|
      seen_during_call = Thread.current[:forge_ops_tracker_breadcrumbs]
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
      seen_during_call = Thread.current[:forge_ops_tracker_breadcrumbs]
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    middleware.call({})

    expect(seen_during_call).to be_nil
  end
end
