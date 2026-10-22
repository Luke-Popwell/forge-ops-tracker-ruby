require "spec_helper"

RSpec.describe ForgeOpsTracker::ErrorSubscriber do
  let(:configuration) { ForgeOpsTracker::Configuration.new }
  let(:delivery_queue) { instance_double(ForgeOpsTracker::DeliveryQueue, push: true) }
  let(:event_builder) { instance_double(ForgeOpsTracker::EventBuilder) }
  let(:error) { RuntimeError.new("boom") }
  # No RequestState on this thread and no snapshot on the error: what a background job or a
  # console session reports with, and what every example below that isn't about request context
  # expects.
  let(:outside_a_request) { { transaction_name: nil, endpoint: nil, trace_id: nil } }

  subject(:subscriber) { described_class.new(configuration, delivery_queue: delivery_queue, event_builder: event_builder) }

  before do
    configuration.dsn = "https://key@tracker.example.com/api/v1/events"
    configuration.enabled_environments = %w[production]
    configuration.environment = "production"
    allow(event_builder).to receive(:build).and_return(exception_class: "RuntimeError")
  end

  it "builds and enqueues a payload when reporting is enabled" do
    subscriber.report(error, handled: true, context: { "a" => 1 })

    expect(event_builder).to have_received(:build).with(error, context: { "a" => 1 }, user: nil, breadcrumbs: [], **outside_a_request)
    expect(delivery_queue).to have_received(:push).with(exception_class: "RuntimeError")
  end

  it "passes along whatever user ForgeOpsTracker::Middleware::UserContext (or .set_user) stashed" do
    Thread.current[:forge_ops_tracker_current_user] = { id: 42, email: "alice@example.com" }

    subscriber.report(error)

    expect(event_builder).to have_received(:build).with(error, context: {}, user: { id: 42, email: "alice@example.com" }, breadcrumbs: [], **outside_a_request)
  ensure
    Thread.current[:forge_ops_tracker_current_user] = nil
  end

  it "passes along whatever breadcrumbs ForgeOpsTracker::Middleware::BreadcrumbContext (or .add_breadcrumb) accumulated" do
    buffer = ForgeOpsTracker::BreadcrumbBuffer.new(configuration)
    buffer.add(category: "query", message: "User Load")
    Thread.current[:forge_ops_tracker_breadcrumbs] = buffer

    subscriber.report(error)

    expect(event_builder).to have_received(:build) do |*_args, **kwargs|
      expect(kwargs[:breadcrumbs].map { |b| b[:message] }).to eq([ "User Load" ])
    end
  ensure
    Thread.current[:forge_ops_tracker_breadcrumbs] = nil
  end

  it "passes an empty breadcrumbs array when there's no buffer on this thread at all" do
    subscriber.report(error)

    expect(event_builder).to have_received(:build).with(error, context: {}, user: nil, breadcrumbs: [], **outside_a_request)
  end

  describe "request context" do
    let(:state) { ForgeOpsTracker::RequestState.new(trace_id: "4bf92f3577b34da6a3ce929d0e0e4736") }

    after do
      Thread.current[:forge_ops_tracker_request_context] = nil
      Thread.current[:forge_ops_tracker_current_user] = nil
      Thread.current[:forge_ops_tracker_breadcrumbs] = nil
    end

    it "passes along the live request's transaction name, endpoint, and trace id" do
      state.controller_started(controller: "CheckoutsController", action: "create", method: "POST")
      Thread.current[:forge_ops_tracker_request_context] = state

      subscriber.report(error)

      expect(event_builder).to have_received(:build).with(
        error, context: {}, user: nil, breadcrumbs: [],
        transaction_name: "CheckoutsController#create", endpoint: "POST CheckoutsController#create",
        trace_id: "4bf92f3577b34da6a3ce929d0e0e4736"
      )
    end

    it "marks the live request errored, so its trace is sent however fast it was" do
      Thread.current[:forge_ops_tracker_request_context] = state

      subscriber.report(error, handled: true)

      expect(state).to be_errored
    end

    it "falls back to the snapshot on the exception once the request's thread-locals are gone" do
      state.controller_started(controller: "CheckoutsController", action: "create", method: "POST")
      Thread.current[:forge_ops_tracker_current_user] = { id: 42 }
      buffer = ForgeOpsTracker::BreadcrumbBuffer.new(configuration)
      buffer.add(category: "custom", message: "charged card")
      Thread.current[:forge_ops_tracker_breadcrumbs] = buffer
      ForgeOpsTracker::Middleware::RequestContext.attach_snapshot(error, state)
      Thread.current[:forge_ops_tracker_current_user] = nil
      Thread.current[:forge_ops_tracker_breadcrumbs] = nil

      subscriber.report(error, handled: false)

      expect(event_builder).to have_received(:build) do |_error, **kwargs|
        expect(kwargs[:user]).to eq(id: 42)
        expect(kwargs[:breadcrumbs].map { |b| b[:message] }).to eq([ "charged card" ])
        expect(kwargs[:transaction_name]).to eq("CheckoutsController#create")
        expect(kwargs[:endpoint]).to eq("POST CheckoutsController#create")
        expect(kwargs[:trace_id]).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
      end
    end

    it "prefers the live thread-locals over the snapshot when both are present" do
      ForgeOpsTracker::Middleware::RequestContext.attach_snapshot(error, ForgeOpsTracker::RequestState.new(trace_id: "a" * 32))
      Thread.current[:forge_ops_tracker_request_context] = state
      Thread.current[:forge_ops_tracker_current_user] = { id: 7 }

      subscriber.report(error)

      expect(event_builder).to have_received(:build) do |_error, **kwargs|
        expect(kwargs[:user]).to eq(id: 7)
        expect(kwargs[:trace_id]).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
      end
    end
  end

  describe "Sidekiq's retry control-flow exception" do
    # Stands in for Sidekiq::JobRetry::Handled/Skip without requiring Sidekiq (an optional
    # dependency this gem never loads): the subscriber matches on the class name, and Skip really
    # is a subclass of Handled.
    before do
      stub_const("Sidekiq::JobRetry::Handled", Class.new(StandardError))
      stub_const("Sidekiq::JobRetry::Skip", Class.new(Sidekiq::JobRetry::Handled))
    end

    # Raised from inside a rescue, the way Sidekiq itself does it, so Ruby sets #cause for real.
    def wrap(wrapper_class, cause)
      raise cause
    rescue StandardError
      begin
        raise wrapper_class
      rescue wrapper_class => wrapped
        wrapped
      end
    end

    it "reports the real error the retry wrapper was raised over, not the wrapper itself" do
      real = ArgumentError.new("the actual failure")
      wrapped = wrap(Sidekiq::JobRetry::Handled, real)

      subscriber.report(wrapped, handled: false)

      expect(event_builder).to have_received(:build).with(real, context: {}, user: nil, breadcrumbs: [], **outside_a_request)
    end

    it "also unwraps Skip, the subclass Sidekiq raises for a job that has retries turned off" do
      real = NameError.new("uninitialized constant OldNameJob")
      wrapped = wrap(Sidekiq::JobRetry::Skip, real)

      subscriber.report(wrapped, handled: false)

      expect(event_builder).to have_received(:build).with(real, context: {}, user: nil, breadcrumbs: [], **outside_a_request)
    end

    it "reports the wrapper itself when it has no cause to unwrap to, rather than dropping it" do
      bare = Sidekiq::JobRetry::Handled.new

      subscriber.report(bare, handled: false)

      expect(event_builder).to have_received(:build).with(bare, context: {}, user: nil, breadcrumbs: [], **outside_a_request)
    end

    it "leaves an ordinary error that merely has a cause alone" do
      outer = begin
        begin
          raise "inner"
        rescue StandardError
          raise ArgumentError, "outer"
        end
      rescue ArgumentError => e
        e
      end

      subscriber.report(outer)

      expect(event_builder).to have_received(:build).with(outer, context: {}, user: nil, breadcrumbs: [], **outside_a_request)
    end
  end

  it "does nothing when reporting is disabled (e.g. wrong environment)" do
    configuration.environment = "development"

    subscriber.report(error)

    expect(delivery_queue).not_to have_received(:push)
  end

  it "never raises even if building the event fails" do
    allow(event_builder).to receive(:build).and_raise("event builder exploded")

    expect { subscriber.report(error) }.not_to raise_error
  end

  it "never raises even if enqueueing fails" do
    allow(delivery_queue).to receive(:push).and_raise("queue exploded")

    expect { subscriber.report(error) }.not_to raise_error
  end

  it "accepts the full Rails.error.subscribe report signature" do
    expect {
      subscriber.report(error, handled: false, severity: :error, context: {}, source: "application")
    }.not_to raise_error
  end
end
