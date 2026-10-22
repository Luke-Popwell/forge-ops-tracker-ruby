require "spec_helper"

RSpec.describe ForgeOpsTracker::Middleware::UserContext do
  let(:configuration) do
    ForgeOpsTracker::Configuration.new.tap do |c|
      c.dsn = "https://key@tracker.example.com/api/v1/events"
      c.enabled_environments = %w[production]
      c.environment = "production"
    end
  end

  let(:devise_like_user) { double("User", id: 42, email: "alice@example.com") }
  let(:warden) { double("Warden::Proxy", user: devise_like_user) }

  after { Thread.current[:forge_ops_tracker_current_user] = nil }

  it "stashes the warden user as a thread-local for the duration of the call, then clears it" do
    seen_during_call = nil
    app = lambda do |_env|
      seen_during_call = Thread.current[:forge_ops_tracker_current_user]
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    response = middleware.call({ "warden" => warden })

    expect(response).to eq([ 200, {}, [ "ok" ] ])
    expect(seen_during_call).to eq(id: 42, email: "alice@example.com")
    expect(Thread.current[:forge_ops_tracker_current_user]).to be_nil
  end

  it "clears the thread-local even when the app raises" do
    app = ->(_env) { raise ArgumentError, "boom" }
    middleware = described_class.new(app, configuration: configuration)

    expect { middleware.call({ "warden" => warden }) }.to raise_error(ArgumentError, "boom")
    expect(Thread.current[:forge_ops_tracker_current_user]).to be_nil
  end

  it "does nothing when there's no warden key in env at all" do
    seen_during_call = :unset
    app = lambda do |_env|
      seen_during_call = Thread.current[:forge_ops_tracker_current_user]
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    middleware.call({})

    expect(seen_during_call).to be_nil
  end

  it "does nothing when warden is present but has no signed-in user" do
    anonymous_warden = double("Warden::Proxy", user: nil)
    seen_during_call = :unset
    app = lambda do |_env|
      seen_during_call = Thread.current[:forge_ops_tracker_current_user]
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    middleware.call({ "warden" => anonymous_warden })

    expect(seen_during_call).to be_nil
  end

  it "duck-types a non-Devise-shaped user, only pulling whatever methods it actually responds to" do
    custom_user = double("CustomUser", id: 7)
    custom_warden = double("Warden::Proxy", user: custom_user)
    seen_during_call = nil
    app = lambda do |_env|
      seen_during_call = Thread.current[:forge_ops_tracker_current_user]
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    middleware.call({ "warden" => custom_warden })

    expect(seen_during_call).to eq(id: 7)
  end

  it "falls back to name when the user has no username" do
    named_user = double("User", id: 1, email: "bob@example.com", name: "Bob")
    named_warden = double("Warden::Proxy", user: named_user)
    seen_during_call = nil
    app = lambda do |_env|
      seen_during_call = Thread.current[:forge_ops_tracker_current_user]
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    middleware.call({ "warden" => named_warden })

    expect(seen_during_call).to eq(id: 1, email: "bob@example.com", username: "Bob")
  end

  it "does not set the thread-local at all when track_current_user is off" do
    configuration.track_current_user = false
    seen_during_call = :unset
    app = lambda do |_env|
      seen_during_call = Thread.current[:forge_ops_tracker_current_user]
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    middleware.call({ "warden" => warden })

    expect(seen_during_call).to be_nil
  end

  it "does not set the thread-local when the configuration itself isn't enabled" do
    configuration.dsn = nil
    seen_during_call = :unset
    app = lambda do |_env|
      seen_during_call = Thread.current[:forge_ops_tracker_current_user]
      [ 200, {}, [ "ok" ] ]
    end
    middleware = described_class.new(app, configuration: configuration)

    middleware.call({ "warden" => warden })

    expect(seen_during_call).to be_nil
  end
end
