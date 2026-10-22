require "net/http"
require "json"
require "uri"

module ForgeOpsTracker
  # Delivers one payload over HTTP. Every failure mode; DNS, connection,
  # timeout, TLS, a non-2xx response; is caught here and turned into a
  # DeliveryStatus rather than a raised exception, since a broken or
  # unreachable tracker must never be able to break the host app. Every
  # deliver_* method answers one of DeliveryStatus::DELIVERED, REJECTED or
  # FAILED (all three are truthy, so compare, never test for truth).
  class Client
    def initialize(configuration)
      @configuration = configuration
    end

    def deliver(payload)
      post(configuration.ingestion_uri, payload)
    end

    # Same delivery contract as deliver above (never raises, returns a
    # DeliveryStatus), just a different endpoint under the same DSN's host and
    # api_key; see Configuration#session_checkins_uri.
    def deliver_session_checkin(payload)
      post(configuration.session_checkins_uri, payload)
    end

    # Same delivery contract again; see Configuration#performance_samples_uri. payload here is a
    # batch (one entry per distinct transaction a flush interval saw), not a single aggregate the
    # way deliver_session_checkin's own payload is, so this posts { samples: [...] } rather than
    # the array bare, matching what Api::V1::PerformanceSamplesController expects.
    def deliver_performance_samples(samples)
      post(configuration.performance_samples_uri, { samples: samples })
    end

    # Same delivery contract again; see Configuration#custom_metrics_uri. payload is a batch of
    # individual capture_metric calls (see MetricBuffer), matching what
    # Api::V1::CustomMetricsController expects.
    def deliver_metrics(entries)
      post(configuration.custom_metrics_uri, { metrics: entries })
    end

    # Same again; see Configuration#infrastructure_metrics_uri and InfrastructureMetricBuffer.
    def deliver_infrastructure_metrics(entries)
      post(configuration.infrastructure_metrics_uri, { metrics: entries })
    end

    # Same again; see Configuration#failure_events_uri and FailureEventBuffer. payload is a batch
    # of individual real failures (matching Api::V1::FailureEventsController's own { failures:
    # [...] } expectation), the same "a list of individually-meaningful entries, not an aggregate"
    # shape deliver_metrics above already has, not deliver_performance_samples' own bucketed one.
    def deliver_failure_events(entries)
      post(configuration.failure_events_uri, { failures: entries })
    end

    # Same delivery contract again; see Configuration#spans_uri and SpanQueue. payload is one
    # whole captured trace (a trace_id plus every span belonging to it), matching what
    # Api::V1::SpansController expects - unlike every other deliver_* method above, this is never
    # a batch of several distinct traces at once; SpanQueue pushes (and this posts) one trace per
    # call, the moment it's ready, rather than accumulating several over a flush interval.
    def deliver_spans(trace_id:, spans:)
      post(configuration.spans_uri, { trace_id: trace_id, spans: spans })
    end

    # Same delivery contract again; see Configuration#changes_uri and ForgeOpsTracker.record_change.
    # One change per call. A plan without change tracking answers 403, which is a REJECTED here.
    def deliver_change(payload)
      post(configuration.changes_uri, payload)
    end

    # Same again; see Configuration#change_snapshots_uri and ChangeSnapshot.
    def deliver_change_snapshot(payload)
      post(configuration.change_snapshots_uri, payload)
    end

    # Same again; see Configuration#query_plans_uri and QueryExplainer. One plan per call. A plan
    # without performance monitoring answers 403, which is a REJECTED here.
    def deliver_query_plan(payload)
      post(configuration.query_plans_uri, payload)
    end

    private
      attr_reader :configuration

      def post(uri, payload)
        return DeliveryStatus::FAILED unless uri

        response = http_for(uri).request(build_request(uri, payload))
        status = DeliveryStatus.for_code(response.code)
        log { "delivery to #{uri.path} answered HTTP #{response.code}" } unless status == DeliveryStatus::DELIVERED
        status
      rescue StandardError => e
        log { "delivery failed: #{e.class}: #{e.message}" }
        DeliveryStatus::FAILED
      end

      def http_for(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = configuration.open_timeout
        http.read_timeout = configuration.read_timeout
        http
      end

      def build_request(uri, payload)
        request = Net::HTTP::Post.new(uri.request_uri)
        request["Authorization"] = "Bearer #{configuration.api_key}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)
        request
      end

      def log
        configuration.logger&.debug { "[ForgeOpsTracker] #{yield}" }
      end
  end
end
