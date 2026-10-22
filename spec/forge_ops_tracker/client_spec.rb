require "spec_helper"

RSpec.describe ForgeOpsTracker::Client do
  let(:configuration) do
    ForgeOpsTracker::Configuration.new.tap do |config|
      config.dsn = "https://secret-key@tracker.example.com/api/v1/events"
    end
  end

  subject(:client) { described_class.new(configuration) }

  let(:http) { instance_double(Net::HTTP) }

  before do
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
  end

  it "returns :delivered on a successful response" do
    allow(http).to receive(:request).and_return(Net::HTTPAccepted.new("1.1", "202", "Accepted"))

    expect(client.deliver(exception_class: "RuntimeError")).to eq(:delivered)
  end

  it "returns :rejected on a non-2xx response" do
    allow(http).to receive(:request).and_return(Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized"))

    expect(client.deliver(exception_class: "RuntimeError")).to eq(:rejected)
  end

  it "returns :failed, without raising, when the request raises a network error" do
    allow(http).to receive(:request).and_raise(SocketError, "getaddrinfo failed")

    expect { client.deliver(exception_class: "RuntimeError") }.not_to raise_error
    expect(client.deliver(exception_class: "RuntimeError")).to eq(:failed)
  end

  it "returns :rejected for a 4xx the server will never accept, and :failed for one worth retrying" do
    statuses = { "400" => :rejected, "403" => :rejected, "413" => :rejected, "422" => :rejected,
                 "408" => :failed, "429" => :failed, "500" => :failed, "503" => :failed }

    statuses.each do |code, expected|
      allow(http).to receive(:request).and_return(Net::HTTPResponse::CODE_TO_OBJ.fetch(code).new("1.1", code, ""))

      expect(client.deliver(exception_class: "RuntimeError")).to eq(expected), "HTTP #{code}"
    end
  end

  it "returns :failed when there is no DSN configured" do
    configuration.dsn = nil

    expect(client.deliver(exception_class: "RuntimeError")).to eq(:failed)
  end

  it "sends the api key as a bearer token and the payload as JSON" do
    sent_request = nil
    allow(http).to receive(:request) { |req| sent_request = req; Net::HTTPAccepted.new("1.1", "202", "Accepted") }

    client.deliver(exception_class: "RuntimeError", message: "boom")

    expect(sent_request["Authorization"]).to eq("Bearer secret-key")
    expect(JSON.parse(sent_request.body)).to eq("exception_class" => "RuntimeError", "message" => "boom")
  end

  describe "#deliver_session_checkin" do
    it "posts to the session_checkins path under the same DSN host, with the same bearer auth" do
      sent_request = nil
      allow(http).to receive(:request) { |req| sent_request = req; Net::HTTPAccepted.new("1.1", "202", "Accepted") }

      result = client.deliver_session_checkin(release: "1.2.3", sessions_count: 10, crashed_sessions_count: 1)

      expect(result).to eq(:delivered)
      expect(sent_request.path).to eq("/api/v1/session_checkins")
      expect(sent_request["Authorization"]).to eq("Bearer secret-key")
      expect(JSON.parse(sent_request.body)).to eq("release" => "1.2.3", "sessions_count" => 10, "crashed_sessions_count" => 1)
    end

    it "returns :failed, without raising, when the request fails" do
      allow(http).to receive(:request).and_raise(SocketError, "getaddrinfo failed")

      expect { client.deliver_session_checkin(release: "1.2.3") }.not_to raise_error
      expect(client.deliver_session_checkin(release: "1.2.3")).to eq(:failed)
    end

    it "returns :failed when there is no DSN configured" do
      configuration.dsn = nil

      expect(client.deliver_session_checkin(release: "1.2.3")).to eq(:failed)
    end
  end

  describe "#deliver_performance_samples" do
    it "posts the batch wrapped in samples: to the performance_samples path under the same DSN host" do
      sent_request = nil
      allow(http).to receive(:request) { |req| sent_request = req; Net::HTTPAccepted.new("1.1", "202", "Accepted") }

      result = client.deliver_performance_samples([ { transaction_name: "PostsController#show", request_count: 5 } ])

      expect(result).to eq(:delivered)
      expect(sent_request.path).to eq("/api/v1/performance_samples")
      expect(sent_request["Authorization"]).to eq("Bearer secret-key")
      expect(JSON.parse(sent_request.body)).to eq("samples" => [ { "transaction_name" => "PostsController#show", "request_count" => 5 } ])
    end

    it "returns :failed, without raising, when the request fails" do
      allow(http).to receive(:request).and_raise(SocketError, "getaddrinfo failed")

      expect { client.deliver_performance_samples([]) }.not_to raise_error
      expect(client.deliver_performance_samples([])).to eq(:failed)
    end
  end

  describe "#deliver_metrics" do
    it "posts the batch wrapped in metrics: to the custom_metrics path under the same DSN host" do
      sent_request = nil
      allow(http).to receive(:request) { |req| sent_request = req; Net::HTTPAccepted.new("1.1", "202", "Accepted") }

      result = client.deliver_metrics([ { metric_name: "signups", value: 1.0 } ])

      expect(result).to eq(:delivered)
      expect(sent_request.path).to eq("/api/v1/custom_metrics")
      expect(JSON.parse(sent_request.body)).to eq("metrics" => [ { "metric_name" => "signups", "value" => 1.0 } ])
    end

    it "returns :failed, without raising, when the request fails" do
      allow(http).to receive(:request).and_raise(SocketError, "getaddrinfo failed")

      expect { client.deliver_metrics([]) }.not_to raise_error
      expect(client.deliver_metrics([])).to eq(:failed)
    end
  end

  describe "#deliver_spans" do
    it "posts the trace_id and spans array to the spans path under the same DSN host" do
      sent_request = nil
      allow(http).to receive(:request) { |req| sent_request = req; Net::HTTPAccepted.new("1.1", "202", "Accepted") }

      result = client.deliver_spans(trace_id: "abc123", spans: [ { span_id: "s1", name: "Controller#action", kind: "controller" } ])

      expect(result).to eq(:delivered)
      expect(sent_request.path).to eq("/api/v1/spans")
      expect(JSON.parse(sent_request.body)).to eq(
        "trace_id" => "abc123", "spans" => [ { "span_id" => "s1", "name" => "Controller#action", "kind" => "controller" } ]
      )
    end

    it "returns :failed, without raising, when the request fails" do
      allow(http).to receive(:request).and_raise(SocketError, "getaddrinfo failed")

      expect { client.deliver_spans(trace_id: "abc123", spans: []) }.not_to raise_error
      expect(client.deliver_spans(trace_id: "abc123", spans: [])).to eq(:failed)
    end
  end

  describe "#deliver_query_plan" do
    it "posts the plan to the query_plans path under the same DSN host, with the same bearer auth" do
      sent_request = nil
      allow(http).to receive(:request) { |req| sent_request = req; Net::HTTPAccepted.new("1.1", "202", "Accepted") }

      result = client.deliver_query_plan(statement: "SELECT 1", db_system: "postgresql", plan: [ { "Plan" => {} } ])

      expect(result).to eq(:delivered)
      expect(sent_request.path).to eq("/api/v1/query_plans")
      expect(sent_request["Authorization"]).to eq("Bearer secret-key")
      expect(JSON.parse(sent_request.body)).to include("statement" => "SELECT 1", "plan" => [ { "Plan" => {} } ])
    end

    it "returns :rejected, without raising, on a 403 from a plan without performance monitoring" do
      allow(http).to receive(:request).and_return(Net::HTTPForbidden.new("1.1", "403", "Forbidden"))

      expect(client.deliver_query_plan(statement: "SELECT 1")).to eq(:rejected)
    end
  end

  describe "#deliver_change" do
    it "posts the change to the changes path under the same DSN host, with the same bearer auth" do
      sent_request = nil
      allow(http).to receive(:request) { |req| sent_request = req; Net::HTTPAccepted.new("1.1", "202", "Accepted") }

      result = client.deliver_change(kind: "config", title: "Raised the timeout")

      expect(result).to eq(:delivered)
      expect(sent_request.path).to eq("/api/v1/changes")
      expect(sent_request["Authorization"]).to eq("Bearer secret-key")
      expect(JSON.parse(sent_request.body)).to eq("kind" => "config", "title" => "Raised the timeout")
    end

    it "returns :rejected, without raising, on a 403 from a plan without change tracking" do
      allow(http).to receive(:request).and_return(Net::HTTPForbidden.new("1.1", "403", "Forbidden"))

      expect(client.deliver_change(kind: "config", title: "x")).to eq(:rejected)
    end
  end

  describe "#deliver_change_snapshot" do
    it "posts the snapshot to the change_snapshots path under the same DSN host" do
      sent_request = nil
      allow(http).to receive(:request) { |req| sent_request = req; Net::HTTPAccepted.new("1.1", "202", "Accepted") }

      client.deliver_change_snapshot(environment: "production", state: { runtime: "ruby 3.4.1" })

      expect(sent_request.path).to eq("/api/v1/change_snapshots")
      expect(JSON.parse(sent_request.body)).to eq("environment" => "production", "state" => { "runtime" => "ruby 3.4.1" })
    end

    it "returns :failed, without raising, when the request fails" do
      allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)

      expect(client.deliver_change_snapshot(environment: "production", state: {})).to eq(:failed)
    end
  end

  describe "#deliver_infrastructure_metrics" do
    it "posts the batch wrapped in metrics: to the infrastructure_metrics path under the same DSN host" do
      sent_request = nil
      allow(http).to receive(:request) { |req| sent_request = req; Net::HTTPAccepted.new("1.1", "202", "Accepted") }

      result = client.deliver_infrastructure_metrics([ { metric_name: "cpu_percent", value: 42.5, hostname: "web-1" } ])

      expect(result).to eq(:delivered)
      expect(sent_request.path).to eq("/api/v1/infrastructure_metrics")
      expect(JSON.parse(sent_request.body)).to eq("metrics" => [ { "metric_name" => "cpu_percent", "value" => 42.5, "hostname" => "web-1" } ])
    end

    it "returns :failed, without raising, when the request fails" do
      allow(http).to receive(:request).and_raise(SocketError, "getaddrinfo failed")

      expect { client.deliver_infrastructure_metrics([]) }.not_to raise_error
      expect(client.deliver_infrastructure_metrics([])).to eq(:failed)
    end
  end
end
