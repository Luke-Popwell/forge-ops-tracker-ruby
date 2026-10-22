require "spec_helper"

RSpec.describe ForgeOpsTracker do
  # Every other spec in this suite tests SessionFlusher/PerformanceFlusher/MetricBuffer/
  # InfrastructureMetricBuffer directly with a Configuration instance passed in explicitly,
  # deliberately never touching the module-level ForgeOpsTracker.configuration/.configure
  # singleton these two methods actually go through; that's the one thing worth covering here
  # instead (the enabled?-gated no-op and the default value), so the singleton's own memoized
  # state (configuration, and the buffers capture_metric/capture_infrastructure_metric lazily
  # create) is reset around each example rather than leaking into any other spec file.
  around do |example|
    described_class.instance_variable_set(:@configuration, nil)
    described_class.instance_variable_set(:@metric_buffer, nil)
    described_class.instance_variable_set(:@infrastructure_metric_buffer, nil)
    described_class.instance_variable_set(:@change_queue, nil)
    example.run
    described_class.instance_variable_set(:@configuration, nil)
    described_class.instance_variable_set(:@metric_buffer, nil)
    described_class.instance_variable_set(:@infrastructure_metric_buffer, nil)
    described_class.instance_variable_set(:@change_queue, nil)
  end

  describe ".capture_metric" do
    it "is a no-op when the gem isn't enabled (no DSN configured)" do
      described_class.configure { |c| c.dsn = nil }

      expect { described_class.capture_metric("signups") }.not_to raise_error
    end

    it "records into the metric buffer, defaulting value to 1.0, when enabled" do
      described_class.configure do |c|
        c.dsn = "https://key@tracker.example.com/api/v1/events"
        c.environment = "production"
      end
      buffer = instance_double(ForgeOpsTracker::MetricBuffer, record: true)
      allow(ForgeOpsTracker::MetricBuffer).to receive(:new).and_return(buffer)

      described_class.capture_metric("signups")

      expect(buffer).to have_received(:record).with(metric_name: "signups", value: 1.0)
    end

    it "passes an explicit value through instead of the default" do
      described_class.configure do |c|
        c.dsn = "https://key@tracker.example.com/api/v1/events"
        c.environment = "production"
      end
      buffer = instance_double(ForgeOpsTracker::MetricBuffer, record: true)
      allow(ForgeOpsTracker::MetricBuffer).to receive(:new).and_return(buffer)

      described_class.capture_metric("revenue", value: 49.0)

      expect(buffer).to have_received(:record).with(metric_name: "revenue", value: 49.0)
    end
  end

  describe ".capture_infrastructure_metric" do
    it "is a no-op when the gem isn't enabled (no DSN configured)" do
      described_class.configure { |c| c.dsn = nil }

      expect { described_class.capture_infrastructure_metric("cpu_percent", value: 42.5) }.not_to raise_error
    end

    it "defaults hostname to Configuration#server_name when not given" do
      described_class.configure do |c|
        c.dsn = "https://key@tracker.example.com/api/v1/events"
        c.environment = "production"
        c.server_name = "web-1"
      end
      buffer = instance_double(ForgeOpsTracker::InfrastructureMetricBuffer, record: true)
      allow(ForgeOpsTracker::InfrastructureMetricBuffer).to receive(:new).and_return(buffer)

      described_class.capture_infrastructure_metric("cpu_percent", value: 42.5)

      expect(buffer).to have_received(:record).with(metric_name: "cpu_percent", value: 42.5, hostname: "web-1")
    end

    it "uses an explicit hostname instead of the default when given" do
      described_class.configure do |c|
        c.dsn = "https://key@tracker.example.com/api/v1/events"
        c.environment = "production"
        c.server_name = "web-1"
      end
      buffer = instance_double(ForgeOpsTracker::InfrastructureMetricBuffer, record: true)
      allow(ForgeOpsTracker::InfrastructureMetricBuffer).to receive(:new).and_return(buffer)

      described_class.capture_infrastructure_metric("cpu_percent", value: 42.5, hostname: "worker-2")

      expect(buffer).to have_received(:record).with(metric_name: "cpu_percent", value: 42.5, hostname: "worker-2")
    end
  end

  describe ".set_user" do
    after { Thread.current[:forge_ops_tracker_current_user] = nil }

    it "sets the same thread-local ForgeOpsTracker::Middleware::UserContext's own Warden detection uses" do
      described_class.set_user(id: 42, email: "alice@example.com")

      expect(Thread.current[:forge_ops_tracker_current_user]).to eq(id: 42, email: "alice@example.com")
    end

    it "omits any field left nil rather than storing it as an explicit nil" do
      described_class.set_user(id: 42)

      expect(Thread.current[:forge_ops_tracker_current_user]).to eq(id: 42)
    end

    it "clears it back to nil when called with nothing, e.g. to override an auto-detected user" do
      Thread.current[:forge_ops_tracker_current_user] = { id: 1 }

      described_class.set_user

      expect(Thread.current[:forge_ops_tracker_current_user]).to be_nil
    end
  end

  describe ".add_breadcrumb" do
    after { Thread.current[:forge_ops_tracker_breadcrumbs] = nil }

    it "adds to the same buffer ForgeOpsTracker::Middleware::BreadcrumbContext's own automatic sources use" do
      buffer = ForgeOpsTracker::BreadcrumbBuffer.new(described_class.configuration)
      Thread.current[:forge_ops_tracker_breadcrumbs] = buffer

      described_class.add_breadcrumb("clicked checkout", category: "ui", level: "info", data: { button: "checkout" })

      entry = buffer.all.first
      expect(entry[:message]).to eq("clicked checkout")
      expect(entry[:category]).to eq("ui")
      expect(entry[:data]).to eq(button: "checkout")
    end

    it "defaults category to custom and level to info" do
      buffer = ForgeOpsTracker::BreadcrumbBuffer.new(described_class.configuration)
      Thread.current[:forge_ops_tracker_breadcrumbs] = buffer

      described_class.add_breadcrumb("something happened")

      entry = buffer.all.first
      expect(entry[:category]).to eq("custom")
      expect(entry[:level]).to eq("info")
    end

    it "lazily creates a buffer on this thread when none exists yet, e.g. outside any web request" do
      expect(Thread.current[:forge_ops_tracker_breadcrumbs]).to be_nil

      described_class.add_breadcrumb("job started")

      expect(Thread.current[:forge_ops_tracker_breadcrumbs]).to be_a(ForgeOpsTracker::BreadcrumbBuffer)
      expect(Thread.current[:forge_ops_tracker_breadcrumbs].all.map { |b| b[:message] }).to eq([ "job started" ])
    end
  end

  describe ".span" do
    after { Thread.current[:forge_ops_tracker_spans] = nil }

    it "still runs and returns the block's own value when there is no current request trace at all" do
      described_class.configure { |c| c.dsn = "https://key@tracker.example.com/api/v1/events"; c.enabled_environments = %w[test]; c.environment = "test" }

      result = described_class.span("PaymentService#charge") { 42 }

      expect(result).to eq(42)
      expect(Thread.current[:forge_ops_tracker_spans]).to be_nil
    end

    it "runs the block plainly, recording nothing, when the gem isn't enabled" do
      described_class.configure { |c| c.dsn = nil }
      buffer = ForgeOpsTracker::SpanBuffer.new
      Thread.current[:forge_ops_tracker_spans] = buffer

      described_class.span("PaymentService#charge") { 1 }

      expect(buffer.spans).to eq([])
    end

    it "records a nested span onto the current thread's SpanBuffer, parented onto whatever was open before it" do
      described_class.configure { |c| c.dsn = "https://key@tracker.example.com/api/v1/events"; c.enabled_environments = %w[test]; c.environment = "test" }
      buffer = ForgeOpsTracker::SpanBuffer.new
      Thread.current[:forge_ops_tracker_spans] = buffer

      described_class.span("PaymentService#charge", kind: "service") { 1 }

      span = buffer.spans.first
      expect(span[:name]).to eq("PaymentService#charge")
      expect(span[:kind]).to eq("service")
      expect(span[:parent_span_id]).to eq(buffer.root_span_id)
      expect(span[:duration_ms]).to be_a(Numeric)
    end

    it "masks the statement on a database span and records the database system" do
      described_class.configure { |c| c.dsn = "https://key@tracker.example.com/api/v1/events"; c.enabled_environments = %w[test]; c.environment = "test" }
      buffer = ForgeOpsTracker::SpanBuffer.new
      Thread.current[:forge_ops_tracker_spans] = buffer

      described_class.span(
        "Load orders", kind: "database", data: { rows: 3 },
        statement: "SELECT * FROM orders WHERE customer_email = 'a@b.co' AND total > 100", db_system: "PostgreSQL"
      ) { 1 }

      data = buffer.spans.first[:data]
      expect(data).to eq(
        rows: 3, "db.statement" => "SELECT * FROM orders WHERE customer_email = ? AND total > ?", "db.system" => "postgresql"
      )
      expect(JSON.generate(buffer.spans)).not_to include("a@b.co")
    end

    it "ignores statement and db_system on a span that isn't a database span" do
      described_class.configure { |c| c.dsn = "https://key@tracker.example.com/api/v1/events"; c.enabled_environments = %w[test]; c.environment = "test" }
      buffer = ForgeOpsTracker::SpanBuffer.new
      Thread.current[:forge_ops_tracker_spans] = buffer

      described_class.span("PaymentService#charge", statement: "SELECT 'secret'", db_system: "postgresql") { 1 }

      expect(buffer.spans.first[:data]).to eq({})
    end

    it "nests a span recorded inside the block under the manual span, not the root" do
      described_class.configure { |c| c.dsn = "https://key@tracker.example.com/api/v1/events"; c.enabled_environments = %w[test]; c.environment = "test" }
      buffer = ForgeOpsTracker::SpanBuffer.new
      Thread.current[:forge_ops_tracker_spans] = buffer

      described_class.span("PaymentService#charge") do
        buffer.record(span_id: "inner", name: "Stripe", kind: "http", started_at: Time.now.utc, duration_ms: 5.0)
      end

      inner = buffer.spans.find { |s| s[:span_id] == "inner" }
      outer = buffer.spans.find { |s| s[:name] == "PaymentService#charge" }
      expect(inner[:parent_span_id]).to eq(outer[:span_id])
    end

    it "does not record when track_tracing is off" do
      described_class.configure { |c| c.dsn = "https://key@tracker.example.com/api/v1/events"; c.enabled_environments = %w[test]; c.environment = "test"; c.track_tracing = false }
      buffer = ForgeOpsTracker::SpanBuffer.new
      Thread.current[:forge_ops_tracker_spans] = buffer

      described_class.span("PaymentService#charge") { 1 }

      expect(buffer.spans).to eq([])
    end

    it "still records the span even when the block raises, then re-raises" do
      described_class.configure { |c| c.dsn = "https://key@tracker.example.com/api/v1/events"; c.enabled_environments = %w[test]; c.environment = "test" }
      buffer = ForgeOpsTracker::SpanBuffer.new
      Thread.current[:forge_ops_tracker_spans] = buffer

      expect {
        described_class.span("PaymentService#charge") { raise ArgumentError, "boom" }
      }.to raise_error(ArgumentError, "boom")

      expect(buffer.spans.first[:name]).to eq("PaymentService#charge")
    end
  end

  describe ".record_change" do
    let(:queue) { instance_double(ForgeOpsTracker::DeliveryQueue, push: true) }

    before do
      allow(ForgeOpsTracker::DeliveryQueue).to receive(:new).and_return(queue)
    end

    def enable
      described_class.configure do |c|
        c.dsn = "https://key@tracker.example.com/api/v1/events"
        c.environment = "production"
      end
    end

    it "is a no-op when the gem isn't enabled (no DSN configured)" do
      described_class.configure { |c| c.dsn = nil }

      expect(described_class.record_change(kind: "config", title: "Raised the timeout")).to be false
      expect(queue).not_to have_received(:push)
    end

    it "queues the change for the changes endpoint, defaulting environment to the configured one" do
      enable

      described_class.record_change(
        kind: "feature_flag", title: "Enabled new_checkout for 10%", details: { flag: "new_checkout", rollout: 10 },
        service: "web", actor: "luke", url: "https://flags.example.com/new_checkout", id: "flag-42",
        occurred_at: Time.utc(2026, 9, 25, 12, 0, 0)
      )

      expect(ForgeOpsTracker::DeliveryQueue).to have_received(:new).with(anything, deliver_with: :deliver_change)
      expect(queue).to have_received(:push).with(
        kind: "feature_flag", title: "Enabled new_checkout for 10%", details: { flag: "new_checkout", rollout: 10 },
        environment: "production", service: "web", actor: "luke", url: "https://flags.example.com/new_checkout",
        id: "flag-42", occurred_at: "2026-09-25T12:00:00.000Z"
      )
    end

    it "leaves out optional fields that weren't given and defaults occurred_at to now" do
      enable

      described_class.record_change(kind: "config", title: "Raised the timeout")

      expect(queue).to have_received(:push) do |payload|
        expect(payload.keys).to contain_exactly(:kind, :title, :details, :environment, :occurred_at)
        expect(Time.iso8601(payload[:occurred_at])).to be_within(5).of(Time.now)
      end
    end

    it "sends an unknown kind as other, since the server rejects anything outside the six kinds" do
      enable

      described_class.record_change(kind: "deploy", title: "Something happened")

      expect(queue).to have_received(:push).with(hash_including(kind: "other"))
    end

    it "accepts a kind given as a symbol" do
      enable

      described_class.record_change(kind: :migration, title: "Backfilled orders")

      expect(queue).to have_received(:push).with(hash_including(kind: "migration"))
    end

    it "truncates the title to 200 characters and ignores details that aren't a Hash" do
      enable

      described_class.record_change(kind: "config", title: "x" * 300, details: "not a hash")

      expect(queue).to have_received(:push).with(hash_including(title: "x" * 200, details: {}))
    end

    it "sends nothing for a blank title, which the server would reject" do
      enable

      expect(described_class.record_change(kind: "config", title: "  ")).to be false
      expect(queue).not_to have_received(:push)
    end

    it "never raises into the caller, even when queueing itself fails" do
      enable
      allow(queue).to receive(:push).and_raise(RuntimeError, "boom")

      expect { described_class.record_change(kind: "config", title: "x") }.not_to raise_error
      expect(described_class.record_change(kind: "config", title: "x")).to be false
    end
  end

  describe ".configure" do
    it "starts the startup change snapshot outside Rails" do
      described_class.configure { |c| c.dsn = "https://key@tracker.example.com/api/v1/events" }

      expect(ForgeOpsTracker::ChangeSnapshot).to have_received(:start).with(described_class.configuration)
    end
  end
end
