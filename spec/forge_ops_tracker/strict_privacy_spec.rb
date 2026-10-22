require "spec_helper"
require "json"
require "tempfile"

RSpec.describe ForgeOpsTracker::StrictPrivacy do
  # A byte-identical copy of sdks/strict_privacy_vectors.json, generated from the server's own
  # StrictPrivacy; every SDK checks itself against the same file.
  vectors = JSON.parse(File.read(File.expand_path("../fixtures/strict_privacy_vectors.json", __dir__), encoding: "UTF-8"))

  describe ".message_fingerprint" do
    vectors.fetch("fingerprint").each do |vector|
      it "normalizes #{vector["message"].inspect} exactly as the server does" do
        expect(described_class.normalize_message(vector["message"])).to eq(vector["normalized"])
      end

      it "fingerprints #{vector["message"].inspect} exactly as the server does" do
        expect(described_class.message_fingerprint(vector["message"])).to eq(vector["fingerprint"])
      end

      it "fingerprints #{vector["message"].inspect} as the SHA-256 of its normalized UTF-8" do
        expect(described_class.message_fingerprint(vector["message"])).to eq(Digest::SHA256.hexdigest(vector["normalized"].encode("UTF-8"))[0, 32])
      end
    end

    it "hashes a binary-labelled message as the UTF-8 it holds" do
      expect(described_class.message_fingerprint("emoji 🎉 1 🎉".b)).to eq(described_class.message_fingerprint("emoji 🎉 1 🎉"))
    end

    it "treats an absent message as an empty one" do
      expect(described_class.message_fingerprint(nil)).to eq(described_class.message_fingerprint(""))
    end
  end

  describe ".span_name" do
    vectors.fetch("span_name").each do |vector|
      it "names #{vector["name"].inspect} as #{vector["strict"].inspect}" do
        expect(described_class.span_name(vector["name"])).to eq(vector["strict"])
      end
    end
  end

  describe ".strict_path" do
    vectors.fetch("path").each do |vector|
      it "reduces #{vector["path"].inspect} to #{vector["strict"].inspect}" do
        expect(described_class.strict_path(vector["path"])).to eq(vector["strict"])
      end
    end
  end

  describe ".transaction_name" do
    it "keeps a route or controller action and cuts a raw path down to its first segment" do
      expect(described_class.transaction_name("PatientsController#show")).to eq("PatientsController#show")
      expect(described_class.transaction_name("GET /patients/:id")).to eq("GET /patients/:id")
      expect(described_class.transaction_name("GET /patients/8821")).to eq("GET /patients/:path")
      expect(described_class.transaction_name(nil)).to be_nil
    end

    it "cuts down an error event's raw-path transaction_name" do
      payload = described_class.event({ message: "boom", backtrace: [], transaction_name: "GET /patients/8821" })

      expect(payload[:transaction_name]).to eq("GET /patients/:path")
    end

    it "cuts down performance samples' raw-path transaction names with strict privacy on, and only then" do
      [ true, false ].each do |strict|
        configuration = ForgeOpsTracker::Configuration.new.tap do |c|
          c.environment = "production"
          c.strict_privacy = strict
        end
        delivered = []
        client = instance_double(ForgeOpsTracker::Client)
        allow(client).to receive(:deliver_performance_samples) { |samples| delivered.concat(samples); :delivered }

        flusher = ForgeOpsTracker::PerformanceFlusher.new(configuration, client: client)
        flusher.record(transaction_name: "GET /patients/8821", duration_ms: 5.0)
        flusher.record(transaction_name: "PatientsController#show", duration_ms: 5.0)
        flusher.flush

        names = delivered.map { |sample| sample[:transaction_name] }.sort
        expect(names).to eq(strict ? [ "GET /patients/:path", "PatientsController#show" ] : [ "GET /patients/8821", "PatientsController#show" ])
      end
    end
  end

  describe "configuration" do
    it "is off with no allowed fields by default" do
      configuration = ForgeOpsTracker::Configuration.new

      expect(configuration.strict_privacy).to be false
      expect(configuration.privacy_allowed_fields).to eq([])
    end

    it "reads FORGE_OPS_STRICT_PRIVACY and FORGE_OPS_PRIVACY_ALLOWED_FIELDS from the environment" do
      stub_const("ENV", ENV.to_h.merge("FORGE_OPS_STRICT_PRIVACY" => "true", "FORGE_OPS_PRIVACY_ALLOWED_FIELDS" => "error_code, feature,"))
      configuration = ForgeOpsTracker::Configuration.new

      expect(configuration.strict_privacy).to be true
      expect(configuration.privacy_allowed_fields).to eq(%w[error_code feature])
    end

    it "lets an explicit setting win over the environment" do
      stub_const("ENV", ENV.to_h.merge("FORGE_OPS_STRICT_PRIVACY" => "true", "FORGE_OPS_PRIVACY_ALLOWED_FIELDS" => "error_code"))
      configuration = ForgeOpsTracker::Configuration.new
      configuration.strict_privacy = false
      configuration.privacy_allowed_fields = [ :feature ]

      expect(configuration.strict_privacy).to be false
      expect(configuration.privacy_allowed_fields).to eq(%w[feature])
    end

    it "treats anything but a true-like value as off" do
      stub_const("ENV", ENV.to_h.merge("FORGE_OPS_STRICT_PRIVACY" => "false"))

      expect(ForgeOpsTracker::Configuration.new.strict_privacy).to be false
    end
  end

  describe "an error event" do
    let(:configuration) do
      ForgeOpsTracker::Configuration.new.tap do |config|
        config.environment = "production"
        config.release = "abc123"
        config.server_name = "web-1"
        config.capture_sql_statement = true
      end
    end
    let(:sql_error_class) do
      Class.new(StandardError) do
        attr_reader :sql

        def initialize(message, sql)
          super(message)
          @sql = sql
        end
      end
    end
    let(:source_file) do
      Tempfile.new([ "app_file", ".rb" ]).tap do |file|
        file.write((1..20).map { |n| "line #{n}" }.join("\n"))
        file.flush
        configuration.app_root = File.dirname(file.path)
      end
    end
    let(:error) do
      stub_const("PatientLookupError", sql_error_class)
      PatientLookupError.new("Couldn't find Patient with id=8821 for jane@example.com", "SELECT * FROM patients WHERE id = 8821").tap do |e|
        e.set_backtrace([ "#{source_file.path}:10:in 'show'" ])
      end
    end
    let(:arguments) do
      {
        context: { "error_code" => "E42", "feature" => { "nested" => "no" }, "diagnosis" => "flu", tier: 3 },
        user: { id: 7, email: "jane@example.com", username: "jane" },
        breadcrumbs: [ { category: "custom", message: "viewed Jane's chart", level: "info", timestamp: "now", data: {} } ],
        transaction_name: "PatientsController#show", endpoint: "GET /patients/8821", trace_id: "a" * 32
      }
    end

    after { source_file.close! }

    def build
      ForgeOpsTracker::EventBuilder.new(configuration).build(error, **arguments)
    end

    it "carries only structured facts with strict privacy on" do
      configuration.strict_privacy = true
      configuration.privacy_allowed_fields = %w[error_code feature tier]

      payload = build

      expect(payload[:message]).to eq("")
      # From the message as it would otherwise have been sent: after PII scrubbing.
      expect(payload[:message_fingerprint]).to eq(described_class.message_fingerprint("Couldn't find Patient with id=8821 for [EMAIL FILTERED]"))
      expect(payload[:message_fingerprint]).to match(/\A[0-9a-f]{32}\z/)
      expect(payload).not_to include(:breadcrumbs, :endpoint, :sql_statement)
      expect(payload[:context]).to eq("error_code" => "E42", "tier" => 3)
      expect(payload).not_to have_key(:tags)
      expect(payload[:user]).to eq(id: "7")
      expect(payload[:backtrace]).to eq([ { file: source_file.path, line: 10, method: "show", in_app: true } ])
      expect(payload[:sql_objects]).to eq(operation: "SELECT", procedures: [], relations: [ "patients" ])
      expect(payload).to include(
        exception_class: "PatientLookupError", environment: "production", release: "abc123", server_name: "web-1",
        transaction_name: "PatientsController#show", trace_id: "a" * 32, sdk_name: "ruby"
      )
      expect(payload.to_s).not_to include("jane", "8821", "flu")
    end

    it "sends no context at all with strict privacy on and no allowed fields" do
      configuration.strict_privacy = true

      payload = build

      expect(payload).not_to include(:context, :tags)
    end

    it "leaves out the user entirely when it has no id" do
      configuration.strict_privacy = true
      arguments[:user] = { email: "jane@example.com" }

      expect(build).not_to have_key(:user)
    end

    it "is exactly as before with strict privacy off" do
      payload = build

      expect(payload[:message]).to eq("Couldn't find Patient with id=8821 for [EMAIL FILTERED]")
      expect(payload).not_to have_key(:message_fingerprint)
      expect(payload[:breadcrumbs].first[:message]).to eq("viewed Jane's chart")
      expect(payload[:endpoint]).to eq("GET /patients/8821")
      expect(payload[:sql_statement]).to eq("SELECT * FROM patients WHERE id = ?")
      expect(payload[:context]).to eq("error_code" => "E42", "feature" => { "nested" => "no" }, "diagnosis" => "flu", tier: 3)
      expect(payload[:user]).to eq(id: 7, email: "jane@example.com", username: "jane")
      expect(payload[:backtrace].first[:context_line]).to eq("line 10")
      expect(payload[:tags]).to eq({})
    end
  end

  describe "breadcrumbs" do
    it "are never recorded with strict privacy on" do
      configuration = ForgeOpsTracker::Configuration.new.tap { |c| c.strict_privacy = true }
      buffer = ForgeOpsTracker::BreadcrumbBuffer.new(configuration)

      buffer.add(category: "custom", message: "viewed Jane's chart")

      expect(buffer.all).to eq([])
    end
  end

  describe "failure events" do
    it "keep the error class but never the message with strict privacy on" do
      configuration = ForgeOpsTracker::Configuration.new.tap do |c|
        c.environment = "production"
        c.strict_privacy = true
      end
      client = instance_double(ForgeOpsTracker::Client)
      delivered = []
      allow(client).to receive(:deliver_failure_events) { |entries| delivered.concat(entries); :delivered }

      buffer = ForgeOpsTracker::FailureEventBuffer.new(configuration, client: client)
      buffer.record(kind: "job", transaction_name: "ChargeJob", error_class: "Stripe::CardError", error_message: "card for Jane declined")
      buffer.record(kind: "dependency", transaction_name: "GET /patients/8821", error_class: "Timeout::Error")
      buffer.flush

      expect(delivered.first).to include(kind: "job", transaction_name: "ChargeJob", error_class: "Stripe::CardError")
      expect(delivered.first).not_to have_key(:error_message)
      expect(delivered.last[:transaction_name]).to eq("GET /patients/:path")
    end
  end

  describe "spans" do
    let(:configuration) do
      ForgeOpsTracker::Configuration.new.tap do |c|
        c.dsn = "https://key@tracker.example.com/api/v1/events"
        c.enabled_environments = %w[production]
        c.environment = "production"
        c.track_tracing = true
        c.trace_capture_threshold_ms = 0
      end
    end
    let(:span_queue) { instance_double(ForgeOpsTracker::SpanQueue) }
    let(:pushed) { [] }
    let(:app) do
      lambda do |_env|
        buffer = Thread.current[:forge_ops_tracker_spans]
        now = Time.now.utc
        buffer.record(span_id: "1" * 16, name: "GET https://api.example.com/patients/42?x=1", kind: "http", started_at: now, duration_ms: 3, data: { status: 200 })
        buffer.record(span_id: "2" * 16, name: "Patient Load", kind: "database", started_at: now, duration_ms: 2,
          data: { "db.statement" => "SELECT * FROM patients WHERE id = ?", "db.system" => "postgresql", "note" => "jane" })
        buffer.pop
        buffer.record(span_id: buffer.root_span_id, name: "PatientsController#show", kind: "controller", started_at: now, duration_ms: 10, root: true)
        [ 200, {}, [ "ok" ] ]
      end
    end

    before do
      allow(ForgeOpsTracker::Railtie).to receive(:span_queue).and_return(span_queue)
      allow(span_queue).to receive(:push) { |entry| pushed << entry; true }
    end

    it "name outbound calls by method and host and keep only db.statement/db.system with strict privacy on" do
      configuration.strict_privacy = true

      ForgeOpsTracker::Middleware::SpanTracing.new(app, configuration: configuration).call({})

      spans = pushed.first[:spans]
      expect(spans.map { |span| span[:name] }).to eq([ "GET api.example.com", "Patient Load", "PatientsController#show" ])
      expect(spans[0]).not_to have_key(:data)
      expect(spans[1][:data]).to eq("db.statement" => "SELECT * FROM patients WHERE id = ?", "db.system" => "postgresql")
      expect(spans[2]).not_to have_key(:data)
    end

    it "are exactly as before with strict privacy off" do
      ForgeOpsTracker::Middleware::SpanTracing.new(app, configuration: configuration).call({})

      spans = pushed.first[:spans]
      expect(spans[0]).to include(name: "GET https://api.example.com/patients/42?x=1", data: { status: 200 })
      expect(spans[1][:data]).to include("note" => "jane")
      expect(spans[2]).to include(data: {})
    end
  end
end
