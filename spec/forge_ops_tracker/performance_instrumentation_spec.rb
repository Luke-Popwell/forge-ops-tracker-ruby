require "spec_helper"
require "json"

RSpec.describe ForgeOpsTracker::PerformanceInstrumentation do
  describe ".controller_transaction_name" do
    it "joins controller and action with a #" do
      name = described_class.controller_transaction_name(controller: "PostsController", action: "show")

      expect(name).to eq("PostsController#show")
    end
  end

  describe ".controller_endpoint" do
    let(:request_class) { Struct.new(:route_uri_pattern) }

    it "combines the HTTP method with the route pattern, dropping Rails' own (.:format) suffix" do
      endpoint = described_class.controller_endpoint(
        controller: "OrdersController", action: "show", method: "GET", request: request_class.new("/orders/:id(.:format)")
      )

      expect(endpoint).to eq("GET /orders/:id")
    end

    it "leaves a pattern with no format suffix alone" do
      endpoint = described_class.controller_endpoint(
        controller: "CheckoutsController", action: "create", method: "POST", request: request_class.new("/checkout")
      )

      expect(endpoint).to eq("POST /checkout")
    end

    it "keeps the root route as / rather than an empty string" do
      endpoint = described_class.controller_endpoint(
        controller: "HomeController", action: "index", method: "GET", request: request_class.new("/(.:format)")
      )

      expect(endpoint).to eq("GET /")
    end

    it "falls back to the transaction name when there's no request in the payload (before Rails 7.1)" do
      endpoint = described_class.controller_endpoint(controller: "CheckoutsController", action: "create", method: "POST")

      expect(endpoint).to eq("POST CheckoutsController#create")
    end

    it "falls back to the transaction name when the request has no route pattern" do
      endpoint = described_class.controller_endpoint(
        controller: "CheckoutsController", action: "create", method: "POST", request: request_class.new(nil)
      )

      expect(endpoint).to eq("POST CheckoutsController#create")
    end

    it "falls back to the transaction name when reading the pattern raises, rather than raising itself" do
      request = Object.new
      def request.route_uri_pattern = raise("boom")

      endpoint = described_class.controller_endpoint(controller: "CheckoutsController", action: "create", method: "POST", request: request)

      expect(endpoint).to eq("POST CheckoutsController#create")
    end
  end

  describe ".query_transaction_name" do
    it "uses the query's own name" do
      expect(described_class.query_transaction_name(name: "User Load")).to eq("User Load")
    end

    it "falls back to a literal SQL for a nameless query" do
      expect(described_class.query_transaction_name(name: nil)).to eq("SQL")
      expect(described_class.query_transaction_name(name: "")).to eq("SQL")
    end

    it "skips Rails' own internal schema-introspection queries" do
      expect(described_class.query_transaction_name(name: "SCHEMA")).to be_nil
    end

    it "skips a cached query, never a real round trip to the database" do
      expect(described_class.query_transaction_name(name: "User Load", cached: true)).to be_nil
    end
  end

  describe ".database_span_data" do
    it "carries the SQL masked, so no literal the query ran with is ever in it" do
      connection = double("connection", adapter_name: "PostgreSQL")
      data = described_class.database_span_data(
        sql: "SELECT * FROM users WHERE email = 'a@b.co' AND id = 42", connection: connection
      )

      expect(data).to eq("db.statement" => "SELECT * FROM users WHERE email = ? AND id = ?", "db.system" => "postgresql")
      expect(JSON.generate(data)).not_to include("a@b.co", "42")
    end

    it "truncates a very long statement" do
      data = described_class.database_span_data(sql: "SELECT #{"x, " * 3_000}y FROM t")

      expect(data["db.statement"].length).to be <= ForgeOpsTracker::SqlStatement::MAX_LENGTH + 3
    end

    it "leaves out db.system when there's no connection, and db.statement when there's no SQL" do
      expect(described_class.database_span_data(sql: "SELECT 1")).to eq("db.statement" => "SELECT ?")
      expect(described_class.database_span_data(sql: nil)).to eq({})
    end
  end

  describe ".db_system" do
    {
      "PostgreSQL" => "postgresql", "PostGIS" => "postgresql", "Mysql2" => "mysql", "Trilogy" => "mysql",
      "SQLite" => "sqlite", "SQLServer" => "mssql", "OracleEnhanced" => "oracle", "CockroachDB" => "cockroachdb"
    }.each do |adapter, system|
      it "maps the #{adapter} adapter to #{system}" do
        expect(described_class.db_system(double("connection", adapter_name: adapter))).to eq(system)
      end
    end

    it "is nil for no connection, or one whose adapter_name raises" do
      broken = double("connection")
      allow(broken).to receive(:adapter_name).and_raise("disconnected")

      expect(described_class.db_system(nil)).to be_nil
      expect(described_class.db_system(broken)).to be_nil
    end
  end

  describe ".job_transaction_name" do
    it "uses the job instance's own class name" do
      job = double("job", class: Class.new { def self.name = "SendWelcomeEmailJob" })

      expect(described_class.job_transaction_name(job: job)).to eq("SendWelcomeEmailJob")
    end
  end

  describe ".job_queue_wait_ms" do
    it "computes the gap between enqueued_at and the given at: time, in milliseconds" do
      job = double("job", enqueued_at: Time.utc(2026, 1, 1, 12, 0, 0))

      wait_ms = described_class.job_queue_wait_ms({ job: job }, at: Time.utc(2026, 1, 1, 12, 0, 2, 500_000))

      expect(wait_ms).to eq(2500.0)
    end

    it "is nil for a job with no enqueued_at, e.g. one run via perform_now" do
      job = double("job", enqueued_at: nil)

      expect(described_class.job_queue_wait_ms({ job: job }, at: Time.now)).to be_nil
    end
  end

  describe ".job_failure_details" do
    it "is nil for a job that completed normally, with no exception_object in the payload" do
      expect(described_class.job_failure_details({})).to be_nil
    end

    it "returns the raised exception's own class name and message when the job failed" do
      error = ArgumentError.new("bad input")

      details = described_class.job_failure_details({ exception_object: error })

      expect(details).to eq(error_class: "ArgumentError", error_message: "bad input")
    end
  end

  describe ".sidekiq_worker_is_active_job_wrapper?" do
    it "is false for a plain object, since ActiveJob isn't loaded in this gem's own test suite" do
      expect(described_class.sidekiq_worker_is_active_job_wrapper?(Object.new)).to be false
    end

    it "is true for a real ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper instance" do
      stub_const("ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper", Class.new)
      wrapper = ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper.new

      expect(described_class.sidekiq_worker_is_active_job_wrapper?(wrapper)).to be true
    end
  end
end
