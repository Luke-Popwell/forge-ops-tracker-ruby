require "spec_helper"
require "logger"
require "stringio"
require "timeout"

RSpec.describe ForgeOpsTracker::QueryExplainer do
  # Stands in for the connection Active Record hands this gem's EXPLAIN: records every statement
  # it's asked to run, in order, and answers the EXPLAIN with whatever plan the test sets up.
  class FakeExplainConnection
    Result = Struct.new(:rows)

    attr_reader :executed, :explained
    attr_accessor :plan, :fail_on, :disconnected

    def initialize(plan: nil)
      @plan = plan || [ { "Plan" => { "Node Type" => "Seq Scan", "Relation Name" => "users" } } ]
      @executed = []
      @explained = []
      @fail_on = nil
      @disconnected = false
    end

    def execute(sql)
      raise ArgumentError, "fake failure on #{sql}" if fail_on && sql.start_with?(fail_on)

      executed << sql
    end

    def exec_query(sql, name, binds)
      raise ArgumentError, "fake failure on EXPLAIN" if fail_on == "EXPLAIN"

      executed << sql
      explained << { sql: sql, name: name, binds: binds }
      Result.new([ [ JSON.generate(plan) ] ])
    end

    def disconnect!
      @disconnected = true
    end
  end

  class FakeExplainPool
    attr_reader :connection, :checked_in, :removed

    def initialize(connection)
      @connection = connection
      @checked_in = []
      @removed = []
      @checkout_error = nil
    end

    def fail_checkout_with(error)
      @checkout_error = error
    end

    def checkout(_timeout)
      raise @checkout_error if @checkout_error

      connection
    end

    def checkin(conn)
      checked_in << conn
    end

    def remove(conn)
      removed << conn
    end
  end

  let(:log) { StringIO.new }
  let(:configuration) do
    ForgeOpsTracker::Configuration.new.tap do |c|
      c.dsn = "https://key@tracker.example.com/api/v1/events"
      c.environment = "production"
      c.explain_slow_queries = true
      c.logger = Logger.new(log)
    end
  end
  let(:client) { instance_double(ForgeOpsTracker::Client, deliver_query_plan: true) }
  let(:now) { [ 1_000.0 ] }
  let(:explain_connection) { FakeExplainConnection.new }
  let(:pool) { FakeExplainPool.new(explain_connection) }
  # The app's own connection: a strict double, so anything this class did to it besides reading
  # its adapter name and pool would fail the example.
  let(:app_connection) { double("app connection", adapter_name: "PostgreSQL", pool: pool) }

  subject(:explainer) { described_class.new(configuration, client: client, clock: -> { now.first }) }

  def payload(sql = "SELECT * FROM users WHERE email = $1", binds: [ "a@b.co" ], connection: app_connection)
    { sql: sql, name: "User Load", binds: [], type_casted_binds: binds, connection: connection }
  end

  # Queues without starting the real worker thread, so each test can run what was queued itself.
  def queued_jobs
    jobs = []
    allow(explainer).to receive(:enqueue) { |job| jobs << job; true }
    jobs
  end

  describe ".explainable?" do
    [
      "SELECT * FROM users WHERE id = 1",
      "  select id from users",
      "/* app:forge,controller:users,action:update */ SELECT * FROM users",
      "-- leading comment\nSELECT 1",
      "SELECT * FROM users WHERE id = 1 /* action:destroy */",
      "SELECT * FROM notes WHERE body = 'please update; then delete'",
      "SELECT * FROM users;",
      "SELECT \"users\".\"updated_at\" FROM \"users\""
    ].each do |sql|
      it "allows #{sql.inspect}" do
        expect(described_class.explainable?(sql)).to be true
      end
    end

    [
      "UPDATE users SET name = 'x'",
      "INSERT INTO users (name) VALUES ('x')",
      "DELETE FROM users",
      "WITH recent AS (SELECT * FROM users) SELECT * FROM recent",
      "SELECT * FROM (WITH gone AS (DELETE FROM users RETURNING *) SELECT * FROM gone) t",
      "SELECT * FROM users; DROP TABLE users",
      "SELECT 1; SELECT 2;",
      "SELECT * FROM users FOR UPDATE",
      "SELECT * FROM users FOR SHARE",
      "SELECT * FROM users for no key update",
      "SELECT * FROM users FOR KEY SHARE SKIP LOCKED",
      "SELECT * FROM users MERGE",
      "EXPLAIN SELECT 1",
      "/* SELECT */ UPDATE users SET a = 1",
      "",
      nil
    ].each do |sql|
      it "refuses #{sql.inspect}" do
        expect(described_class.explainable?(sql)).to be false
      end
    end
  end

  describe ".mask_plan" do
    it "masks every string in the plan, leaving keys, numbers and structure alone" do
      plan = [
        {
          "Plan" => {
            "Node Type" => "Index Scan", "Index Name" => "index_users_on_email2",
            "Index Cond" => "(email = 'a@b.co'::text)", "Filter" => "(age > 42)",
            "Total Cost" => 8.27, "Plan Rows" => 1, "Parallel Aware" => false,
            "Output" => [ "id", "'secret'::text" ],
            "Plans" => [ { "Filter" => "(token = 'tok_123')" } ]
          }
        }
      ]

      masked = described_class.mask_plan(plan)

      expect(masked).to eq([
        {
          "Plan" => {
            "Node Type" => "Index Scan", "Index Name" => "index_users_on_email2",
            "Index Cond" => "(email = ?::text)", "Filter" => "(age > ?)",
            "Total Cost" => 8.27, "Plan Rows" => 1, "Parallel Aware" => false,
            "Output" => [ "id", "?::text" ],
            "Plans" => [ { "Filter" => "(token = ?)" } ]
          }
        }
      ])
      expect(JSON.generate(masked)).not_to include("a@b.co", "secret", "tok_123")
    end
  end

  describe "#consider" do
    it "does nothing when explain_slow_queries is off (the default)" do
      configuration.explain_slow_queries = ForgeOpsTracker::Configuration.new.explain_slow_queries
      jobs = queued_jobs

      expect(explainer.consider(payload, duration_ms: 5_000)).to be false
      expect(jobs).to be_empty
    end

    it "does nothing under strict privacy, even with explain_slow_queries on" do
      configuration.strict_privacy = true
      jobs = queued_jobs

      expect(explainer.consider(payload, duration_ms: 5_000)).to be false
      expect(jobs).to be_empty
    end

    it "only takes queries at or above explain_threshold_ms" do
      jobs = queued_jobs

      expect(explainer.consider(payload("SELECT 1 FROM a"), duration_ms: 499.9)).to be false
      expect(explainer.consider(payload("SELECT 1 FROM b"), duration_ms: 500)).to be true
      configuration.explain_threshold_ms = 2_000
      expect(explainer.consider(payload("SELECT 1 FROM c"), duration_ms: 1_999)).to be false
      expect(jobs.size).to eq(1)
    end

    it "only takes PostgreSQL" do
      jobs = queued_jobs
      mysql = double("mysql connection", adapter_name: "Mysql2", pool: pool)

      expect(explainer.consider(payload(connection: mysql), duration_ms: 900)).to be false
      expect(explainer.consider(payload(connection: nil), duration_ms: 900)).to be false
      expect(jobs).to be_empty
    end

    it "only takes a single plain SELECT" do
      jobs = queued_jobs

      [
        "UPDATE users SET a = 1",
        "WITH d AS (DELETE FROM users RETURNING *) SELECT * FROM d",
        "SELECT * FROM users FOR UPDATE",
        "SELECT 1; SELECT 2"
      ].each { |sql| expect(explainer.consider(payload(sql), duration_ms: 900)).to be false }
      expect(jobs).to be_empty
    end

    it "keeps the original statement and binds for the EXPLAIN, and the masked statement for sending" do
      jobs = queued_jobs

      explainer.consider(payload("SELECT * FROM users WHERE email = 'a@b.co' AND id = $1", binds: -> { [ 42 ] }), duration_ms: 812.345)

      job = jobs.first
      expect(job.sql).to eq("SELECT * FROM users WHERE email = 'a@b.co' AND id = $1")
      expect(job.binds).to eq([ 42 ])
      expect(job.statement).to eq("SELECT * FROM users WHERE email = ? AND id = $1")
      expect(job.duration_ms).to eq(812.3)
      expect(job.pool).to be(pool)
    end

    it "explains each distinct statement at most once per 10 minutes" do
      jobs = queued_jobs

      expect(explainer.consider(payload, duration_ms: 900)).to be true
      now[0] += 599
      expect(explainer.consider(payload, duration_ms: 900)).to be false
      # Different literals, same masked statement: still the same statement.
      expect(explainer.consider(payload("SELECT * FROM users WHERE email = 'x@y.z'"), duration_ms: 900)).to be true
      expect(explainer.consider(payload("SELECT * FROM users WHERE email = 'other@y.z'"), duration_ms: 900)).to be false
      now[0] += 1
      expect(explainer.consider(payload, duration_ms: 900)).to be true
      expect(jobs.size).to eq(3)
    end

    it "explains at most 10 statements per minute overall" do
      jobs = queued_jobs

      results = 11.times.map { |i| explainer.consider(payload("SELECT * FROM table_#{("a".ord + i).chr}"), duration_ms: 900) }
      expect(results.count(true)).to eq(10)

      now[0] += 59
      expect(explainer.consider(payload("SELECT * FROM later_one"), duration_ms: 900)).to be false
      now[0] += 1
      expect(explainer.consider(payload("SELECT * FROM later_two"), duration_ms: 900)).to be true
      expect(jobs.size).to eq(11)
    end

    it "never raises, even when the payload is broken" do
      broken = double("connection", adapter_name: "PostgreSQL")
      allow(broken).to receive(:pool).and_raise("boom")

      expect(explainer.consider(payload(connection: broken), duration_ms: 900)).to be false
      expect(explainer.consider({}, duration_ms: 900)).to be false
      expect(explainer.consider(payload, duration_ms: nil)).to be false
    end

    it "runs the EXPLAIN on its own background thread, not the caller's" do
      delivered = Queue.new
      threads = Queue.new
      allow(client).to receive(:deliver_query_plan) { |plan| threads << Thread.current; delivered << plan }

      explainer.consider(payload, duration_ms: 900)

      expect(Timeout.timeout(2) { delivered.pop }[:statement]).to eq("SELECT * FROM users WHERE email = $1")
      expect(Timeout.timeout(2) { threads.pop }).not_to eq(Thread.current)
      expect(described_class.explaining?).to be false
    end
  end

  describe "#perform" do
    def job_for(sql = "SELECT * FROM users WHERE email = $1", binds: [ "a@b.co" ])
      jobs = queued_jobs
      explainer.consider(payload(sql, binds: binds), duration_ms: 900)
      jobs.first
    end

    it "runs EXPLAIN (FORMAT JSON) on a checked-out connection in a read-only, time-limited, rolled-back transaction" do
      explainer.perform(job_for)

      expect(explain_connection.executed).to eq([
        "BEGIN READ ONLY",
        "SET LOCAL statement_timeout = '2s'",
        "EXPLAIN (FORMAT JSON) SELECT * FROM users WHERE email = $1",
        "ROLLBACK"
      ])
      expect(explain_connection.explained.first[:binds]).to eq([ "a@b.co" ])
      expect(explain_connection.executed.join).not_to include("ANALYZE")
      expect(pool.checked_in).to eq([ explain_connection ])
    end

    it "never touches the app's own connection" do
      # app_connection is a strict double allowing only adapter_name and pool; anything else raises
      # RSpec::Mocks::MockExpectationError, which isn't a StandardError, so it isn't swallowed.
      explainer.perform(job_for)

      expect(app_connection).to have_received(:adapter_name).at_least(:once)
    end

    it "sends the masked statement and the masked plan, never a literal or a bind value" do
      explain_connection.plan = [ { "Plan" => { "Node Type" => "Seq Scan", "Filter" => "(email = 'a@b.co'::text)", "Plan Rows" => 3 } } ]

      explainer.perform(job_for("SELECT * FROM users WHERE email = 'a@b.co'", binds: []))

      expect(client).to have_received(:deliver_query_plan) do |plan|
        expect(plan).to include(
          statement: "SELECT * FROM users WHERE email = ?", db_system: "postgresql",
          plan: [ { "Plan" => { "Node Type" => "Seq Scan", "Filter" => "(email = ?::text)", "Plan Rows" => 3 } } ],
          duration_ms: 900.0, environment: "production"
        )
        expect(plan[:captured_at]).to match(/\A\d{4}-\d{2}-\d{2}T/)
        expect(JSON.generate(plan)).not_to include("a@b.co")
      end
    end

    it "drops a plan over 64 KB instead of sending it" do
      explain_connection.plan = [ { "Plan" => { "Output" => Array.new(10_000) { |i| "column_number_#{i}" } } } ]

      expect(explainer.perform(job_for)).to be false
      expect(client).not_to have_received(:deliver_query_plan)
      expect(log.string).to include("dropped")
    end

    it "swallows an exhausted pool, logging at debug" do
      pool.fail_checkout_with(Timeout::Error.new("could not obtain a connection from the pool"))

      expect { explainer.perform(job_for) }.not_to raise_error
      expect(client).not_to have_received(:deliver_query_plan)
      expect(log.string).to include("EXPLAIN failed", "could not obtain a connection")
    end

    it "swallows a failing EXPLAIN (a timeout, a permission error), still rolling back and checking the connection in" do
      explain_connection.fail_on = "EXPLAIN"

      expect(explainer.perform(job_for)).to be false
      expect(explain_connection.executed.last).to eq("ROLLBACK")
      expect(pool.checked_in).to eq([ explain_connection ])
      expect(client).not_to have_received(:deliver_query_plan)
    end

    it "removes and closes the connection instead of returning it to the pool when even the rollback fails" do
      explain_connection.fail_on = "ROLLBACK"

      explainer.perform(job_for)

      expect(pool.checked_in).to be_empty
      expect(pool.removed).to eq([ explain_connection ])
      expect(explain_connection.disconnected).to be true
    end

    it "swallows a delivery failure" do
      allow(client).to receive(:deliver_query_plan).and_raise("network down")

      expect(explainer.perform(job_for)).to be false
    end
  end
end
