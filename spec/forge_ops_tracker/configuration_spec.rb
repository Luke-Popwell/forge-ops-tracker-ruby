require "spec_helper"

RSpec.describe ForgeOpsTracker::Configuration do
  subject(:configuration) { described_class.new }

  before do
    configuration.dsn = nil
    configuration.enabled_environments = %w[production staging]
    configuration.environment = "production"
  end

  describe "#api_key and #ingestion_uri" do
    it "extracts the api_key and a credential-free ingestion URL from the DSN" do
      configuration.dsn = "https://secret-key@tracker.example.com/api/v1/events"

      expect(configuration.api_key).to eq("secret-key")
      expect(configuration.ingestion_uri.to_s).to eq("https://tracker.example.com/api/v1/events")
    end

    it "returns nil for both when there is no DSN" do
      configuration.dsn = nil

      expect(configuration.api_key).to be_nil
      expect(configuration.ingestion_uri).to be_nil
    end

    it "returns nil for both when the DSN is malformed" do
      configuration.dsn = "not a uri :: at all"

      expect(configuration.api_key).to be_nil
      expect(configuration.ingestion_uri).to be_nil
    end
  end

  describe "#capture_source_context" do
    it "defaults to true" do
      expect(configuration.capture_source_context).to be true
    end
  end

  describe "SQL capture" do
    it "sends procedure/table/view names by default, but not the statement itself" do
      expect(configuration.capture_sql_objects).to be true
      expect(configuration.capture_sql_statement).to be false
    end
  end

  describe "#track_sessions" do
    it "defaults to true, the same 'on unless turned off' default error tracking already has" do
      expect(configuration.track_sessions).to be true
    end
  end

  describe "#session_flush_interval" do
    it "defaults to 60 seconds" do
      expect(configuration.session_flush_interval).to eq(60)
    end
  end

  describe "#session_checkins_uri" do
    it "derives the session-checkins path from the same DSN host, not a second DSN" do
      configuration.dsn = "https://secret-key@tracker.example.com/api/v1/events"

      expect(configuration.session_checkins_uri.to_s).to eq("https://tracker.example.com/api/v1/session_checkins")
    end

    it "returns nil when there is no DSN" do
      configuration.dsn = nil

      expect(configuration.session_checkins_uri).to be_nil
    end
  end

  describe "#track_performance" do
    it "defaults to true, the same 'on unless turned off' default as track_sessions" do
      expect(configuration.track_performance).to be true
    end
  end

  describe "#performance_flush_interval" do
    it "defaults to 60 seconds" do
      expect(configuration.performance_flush_interval).to eq(60)
    end
  end

  describe "#performance_samples_uri" do
    it "derives the performance-samples path from the same DSN host, not a second DSN" do
      configuration.dsn = "https://secret-key@tracker.example.com/api/v1/events"

      expect(configuration.performance_samples_uri.to_s).to eq("https://tracker.example.com/api/v1/performance_samples")
    end

    it "returns nil when there is no DSN" do
      configuration.dsn = nil

      expect(configuration.performance_samples_uri).to be_nil
    end
  end

  describe "#track_failures" do
    it "defaults to true, the same 'on unless turned off' default as track_performance" do
      expect(configuration.track_failures).to be true
    end
  end

  describe "#failure_event_flush_interval" do
    it "defaults to 60 seconds" do
      expect(configuration.failure_event_flush_interval).to eq(60)
    end
  end

  describe "#failure_events_uri" do
    it "derives the failure-events path from the same DSN host, not a second DSN" do
      configuration.dsn = "https://secret-key@tracker.example.com/api/v1/events"

      expect(configuration.failure_events_uri.to_s).to eq("https://tracker.example.com/api/v1/failure_events")
    end

    it "returns nil when there is no DSN" do
      configuration.dsn = nil

      expect(configuration.failure_events_uri).to be_nil
    end
  end

  describe "#track_tracing" do
    it "defaults to true, the same 'on unless turned off' default as track_performance/track_failures" do
      expect(configuration.track_tracing).to be true
    end
  end

  describe "#trace_capture_threshold_ms" do
    it "defaults to 1000ms" do
      expect(configuration.trace_capture_threshold_ms).to eq(1_000)
    end
  end

  describe "#propagate_traces" do
    it "defaults to true" do
      expect(configuration.propagate_traces).to be true
    end
  end

  describe "#trace_propagation_targets" do
    it "defaults to nil, meaning every host" do
      expect(configuration.trace_propagation_targets).to be_nil
    end
  end

  describe "#propagate_trace_to?" do
    it "is true for any host by default" do
      expect(configuration.propagate_trace_to?("api.stripe.example")).to be true
    end

    it "is false for every host once propagate_traces is off" do
      configuration.propagate_traces = false

      expect(configuration.propagate_trace_to?("api.internal.example")).to be false
    end

    it "matches a String target as the exact host or any subdomain of it, not an unrelated host sharing a suffix" do
      configuration.trace_propagation_targets = [ "internal.example" ]

      expect(configuration.propagate_trace_to?("internal.example")).to be true
      expect(configuration.propagate_trace_to?("orders.internal.example")).to be true
      expect(configuration.propagate_trace_to?("notinternal.example")).to be false
      expect(configuration.propagate_trace_to?("api.stripe.example")).to be false
    end

    it "treats a leading dot on a String target the same as none" do
      configuration.trace_propagation_targets = [ ".internal.example" ]

      expect(configuration.propagate_trace_to?("orders.internal.example")).to be true
    end

    it "matches hosts case-insensitively" do
      configuration.trace_propagation_targets = [ "Internal.Example" ]

      expect(configuration.propagate_trace_to?("ORDERS.internal.example")).to be true
    end

    it "matches a Regexp target against the host" do
      configuration.trace_propagation_targets = [ /\A10\.0\.\d+\.\d+\z/ ]

      expect(configuration.propagate_trace_to?("10.0.3.7")).to be true
      expect(configuration.propagate_trace_to?("192.168.0.1")).to be false
    end

    it "accepts a mix of Strings and Regexps, and an empty list matches nothing" do
      configuration.trace_propagation_targets = [ "internal.example", /\.svc\z/ ]
      expect(configuration.propagate_trace_to?("billing.svc")).to be true

      configuration.trace_propagation_targets = []
      expect(configuration.propagate_trace_to?("internal.example")).to be false
    end
  end

  describe "#spans_uri" do
    it "derives the spans path from the same DSN host, not a second DSN" do
      configuration.dsn = "https://secret-key@tracker.example.com/api/v1/events"

      expect(configuration.spans_uri.to_s).to eq("https://tracker.example.com/api/v1/spans")
    end

    it "returns nil when there is no DSN" do
      configuration.dsn = nil

      expect(configuration.spans_uri).to be_nil
    end
  end

  describe "EXPLAIN of slow queries" do
    it "is off by default, with a 500ms threshold" do
      expect(configuration.explain_slow_queries).to be false
      expect(configuration.explain_threshold_ms).to eq(500)
    end
  end

  describe "#query_plans_uri" do
    it "derives the query_plans path from the same DSN host" do
      configuration.dsn = "https://secret-key@tracker.example.com/api/v1/events"

      expect(configuration.query_plans_uri.to_s).to eq("https://tracker.example.com/api/v1/query_plans")
    end

    it "returns nil when there is no DSN" do
      configuration.dsn = nil

      expect(configuration.query_plans_uri).to be_nil
    end
  end

  describe "#metric_flush_interval" do
    it "defaults to 60 seconds" do
      expect(configuration.metric_flush_interval).to eq(60)
    end
  end

  describe "#custom_metrics_uri" do
    it "derives the custom-metrics path from the same DSN host, not a second DSN" do
      configuration.dsn = "https://secret-key@tracker.example.com/api/v1/events"

      expect(configuration.custom_metrics_uri.to_s).to eq("https://tracker.example.com/api/v1/custom_metrics")
    end

    it "returns nil when there is no DSN" do
      configuration.dsn = nil

      expect(configuration.custom_metrics_uri).to be_nil
    end
  end

  describe "#infrastructure_metric_flush_interval" do
    it "defaults to 60 seconds" do
      expect(configuration.infrastructure_metric_flush_interval).to eq(60)
    end
  end

  describe "#infrastructure_metrics_uri" do
    it "derives the infrastructure-metrics path from the same DSN host, not a second DSN" do
      configuration.dsn = "https://secret-key@tracker.example.com/api/v1/events"

      expect(configuration.infrastructure_metrics_uri.to_s).to eq("https://tracker.example.com/api/v1/infrastructure_metrics")
    end

    it "returns nil when there is no DSN" do
      configuration.dsn = nil

      expect(configuration.infrastructure_metrics_uri).to be_nil
    end
  end

  describe "#enabled?" do
    it "is true with a valid DSN in an enabled environment" do
      configuration.dsn = "https://key@tracker.example.com/api/v1/events"
      configuration.environment = "production"

      expect(configuration).to be_enabled
    end

    it "is false with no DSN configured" do
      configuration.dsn = nil
      expect(configuration).not_to be_enabled
    end

    it "is false when the DSN has no api key" do
      configuration.dsn = "https://tracker.example.com/api/v1/events"
      expect(configuration).not_to be_enabled
    end

    it "is false outside the configured enabled_environments" do
      configuration.dsn = "https://key@tracker.example.com/api/v1/events"
      configuration.environment = "development"

      expect(configuration).not_to be_enabled
    end
  end
end
