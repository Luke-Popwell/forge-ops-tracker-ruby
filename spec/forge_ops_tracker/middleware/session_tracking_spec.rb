require "spec_helper"

RSpec.describe ForgeOpsTracker::Middleware::SessionTracking do
  let(:configuration) do
    ForgeOpsTracker::Configuration.new.tap do |c|
      c.dsn = "https://key@tracker.example.com/api/v1/events"
      c.enabled_environments = %w[production]
      c.environment = "production"
    end
  end

  let(:flusher) { instance_double(ForgeOpsTracker::SessionFlusher, record_session: nil) }

  it "counts a normal request as a non-crashed session and returns the app's own response" do
    app = ->(_env) { [ 200, {}, [ "ok" ] ] }
    middleware = described_class.new(app, configuration: configuration, flusher: flusher)

    response = middleware.call({})

    expect(response).to eq([ 200, {}, [ "ok" ] ])
    expect(flusher).to have_received(:record_session).with(crashed: false)
  end

  it "counts a request an exception escapes as a crashed session, then re-raises the same exception" do
    app = ->(_env) { raise ArgumentError, "boom" }
    middleware = described_class.new(app, configuration: configuration, flusher: flusher)

    expect { middleware.call({}) }.to raise_error(ArgumentError, "boom")
    expect(flusher).to have_received(:record_session).with(crashed: true)
  end

  it "does not count anything, and does not build a flusher, when track_sessions is off" do
    configuration.track_sessions = false
    app = ->(_env) { [ 200, {}, [ "ok" ] ] }
    middleware = described_class.new(app, configuration: configuration, flusher: flusher)

    middleware.call({})

    expect(flusher).not_to have_received(:record_session)
  end

  it "does not count anything when the configuration itself isn't enabled (no DSN, wrong environment)" do
    configuration.dsn = nil
    app = ->(_env) { [ 200, {}, [ "ok" ] ] }
    middleware = described_class.new(app, configuration: configuration, flusher: flusher)

    middleware.call({})

    expect(flusher).not_to have_received(:record_session)
  end
end
