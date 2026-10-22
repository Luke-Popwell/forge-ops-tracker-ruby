require "spec_helper"
require "redis_client"
require "forge_ops_tracker/integrations/redis_client"

RSpec.describe ForgeOpsTracker::Integrations::RedisClientTiming do
  # A real local Redis server, not a stubbed RedisClient#call: Timing wraps the real method via
  # Module#prepend and calls `super`, the same "a real round trip is what actually proves this,
  # not a stubbed one" reasoning net_http_spec.rb's own top comment gives for using a real WEBrick
  # server instead of a stubbed Net::HTTP.
  let(:redis) { RedisClient.new(host: "127.0.0.1", port: 6379) }

  let(:configuration) do
    ForgeOpsTracker::Configuration.new.tap do |c|
      c.dsn = "https://key@tracker.example.com/api/v1/events"
      c.enabled_environments = %w[test]
      c.environment = "test"
      c.track_tracing = true
    end
  end
  let(:failure_buffer) { instance_double(ForgeOpsTracker::FailureEventBuffer, record: nil) }

  before do
    allow(ForgeOpsTracker).to receive(:configuration).and_return(configuration)
    allow(ForgeOpsTracker::Railtie).to receive(:failure_event_buffer).and_return(failure_buffer)
    RedisClient.prepend(described_class) unless RedisClient.ancestors.include?(described_class)
  end

  after do
    Thread.current[:forge_ops_tracker_breadcrumbs] = nil
    Thread.current[:forge_ops_tracker_spans] = nil
  end

  it "still performs the real command and returns the real result" do
    expect(redis.call("SET", "forge_ops_tracker_spec_key", "bar")).to eq("OK")
    expect(redis.call("GET", "forge_ops_tracker_spec_key")).to eq("bar")
  end

  it "records an http-adjacent redis span onto the current request's SpanBuffer, named after the command verb alone, never the key" do
    buffer = ForgeOpsTracker::SpanBuffer.new
    Thread.current[:forge_ops_tracker_spans] = buffer

    redis.call("GET", "forge_ops_tracker_spec_key")

    span = buffer.spans.first
    expect(span[:name]).to eq("Redis GET")
    expect(span[:kind]).to eq("redis")
    expect(span[:parent_span_id]).to eq(buffer.root_span_id)
    expect(span[:duration_ms]).to be_a(Numeric)
  end

  it "does not record a span when there is no current request trace at all" do
    expect { redis.call("GET", "forge_ops_tracker_spec_key") }.not_to raise_error
  end

  it "does not record a span when track_tracing is off" do
    configuration.track_tracing = false
    buffer = ForgeOpsTracker::SpanBuffer.new
    Thread.current[:forge_ops_tracker_spans] = buffer

    redis.call("GET", "forge_ops_tracker_spec_key")

    expect(buffer.spans).to eq([])
  end

  it "records a redis breadcrumb with the command and duration" do
    redis.call("GET", "forge_ops_tracker_spec_key")

    entry = Thread.current[:forge_ops_tracker_breadcrumbs].all.first
    expect(entry[:category]).to eq("redis")
    expect(entry[:message]).to eq("Redis GET")
    expect(entry[:level]).to eq("info")
    expect(entry[:data][:duration_ms]).to be_a(Numeric)
  end

  it "records a dependency failure, with the real error class/message, when the command itself raises" do
    unreachable = RedisClient.new(host: "127.0.0.1", port: 1)

    expect { unreachable.call("GET", "forge_ops_tracker_spec_key") }.to raise_error(RedisClient::Error)

    expect(failure_buffer).to have_received(:record).with(kind: "dependency", transaction_name: "Redis GET", error_class: kind_of(String), error_message: kind_of(String))
  end

  it "does not record a dependency failure for a successful command" do
    redis.call("GET", "forge_ops_tracker_spec_key")

    expect(failure_buffer).not_to have_received(:record)
  end

  it "does not record a dependency failure when track_failures is off" do
    configuration.track_failures = false
    unreachable = RedisClient.new(host: "127.0.0.1", port: 1)

    expect { unreachable.call("GET", "forge_ops_tracker_spec_key") }.to raise_error(RedisClient::Error)

    expect(failure_buffer).not_to have_received(:record)
  end
end
