require "spec_helper"
require "json"
require "logger"
require "open3"
require "rbconfig"
require "rack"
require "rack/mock"
require "webrick"

# The environment default, the one-time "Not sending" warning, ForgeOpsTracker.capture_exception,
# and the Rack middleware reporting outside Rails, including end-to-end runs of a fresh `ruby`
# against a local HTTP server, the way a new customer's script would run.
RSpec.describe "Environment default and non-Rails reporting" do
  let(:dsn) { "https://key@tracker.example.com/api/v1/events" }
  let(:warning) do
    '[ForgeOps] Not sending: this environment is "development", and only production, staging are enabled. ' \
      'Set FORGE_OPS_ENVIRONMENT=production (or add "development" to enabled_environments) to send from here.'
  end

  def reset_module_state
    ForgeOpsTracker.instance_variable_set(:@configuration, nil)
    ForgeOpsTracker.instance_variable_set(:@error_subscriber, nil)
    ForgeOpsTracker.instance_variable_set(:@environment_warning_logged, nil)
  end

  around do |example|
    reset_module_state
    example.run
  ensure
    reset_module_state
    Thread.current[:forge_ops_tracker_request_context] = nil
  end

  describe "Configuration.resolve_environment" do
    it "is production when nothing is set" do
      expect(ForgeOpsTracker::Configuration.resolve_environment({})).to eq("production")
    end

    it "prefers FORGE_OPS_ENVIRONMENT, then RAILS_ENV, then RACK_ENV" do
      all = { "FORGE_OPS_ENVIRONMENT" => "staging", "RAILS_ENV" => "development", "RACK_ENV" => "test" }

      expect(ForgeOpsTracker::Configuration.resolve_environment(all)).to eq("staging")
      expect(ForgeOpsTracker::Configuration.resolve_environment(all.except("FORGE_OPS_ENVIRONMENT"))).to eq("development")
      expect(ForgeOpsTracker::Configuration.resolve_environment("RACK_ENV" => "test")).to eq("test")
    end

    it "treats a blank value as unset" do
      expect(ForgeOpsTracker::Configuration.resolve_environment("FORGE_OPS_ENVIRONMENT" => " ", "RACK_ENV" => "")).to eq("production")
    end

    it "leaves the enabled_environments default alone" do
      expect(ForgeOpsTracker::Configuration.new.enabled_environments).to eq(%w[production staging])
    end
  end

  describe "ForgeOpsTracker.warn_if_environment_disabled" do
    it "logs the warning once to the configured logger" do
      logger = instance_double(Logger, warn: nil)
      ForgeOpsTracker.configuration.tap { |c| c.dsn = dsn; c.environment = "development"; c.logger = logger }

      expect(ForgeOpsTracker.warn_if_environment_disabled).to be(true)
      expect(ForgeOpsTracker.warn_if_environment_disabled).to be(false)
      expect(logger).to have_received(:warn).once.with(warning)
    end

    it "prints to stderr when there's no logger" do
      ForgeOpsTracker.configuration.tap { |c| c.dsn = dsn; c.environment = "development"; c.logger = nil }

      expect { ForgeOpsTracker.configure { |c| c.dsn = dsn } }.to output("#{warning}\n").to_stderr
    end

    it "never logs without a DSN" do
      ForgeOpsTracker.configuration.tap { |c| c.dsn = nil; c.environment = "development"; c.logger = nil }

      expect { expect(ForgeOpsTracker.warn_if_environment_disabled).to be(false) }.not_to output.to_stderr
    end

    it "doesn't log in an enabled environment" do
      ForgeOpsTracker.configuration.tap { |c| c.dsn = dsn; c.environment = "staging"; c.logger = nil }

      expect { expect(ForgeOpsTracker.warn_if_environment_disabled).to be(false) }.not_to output.to_stderr
    end
  end

  describe "ForgeOpsTracker.capture_exception" do
    let(:delivery_queue) { instance_double(ForgeOpsTracker::DeliveryQueue, push: true) }

    before do
      ForgeOpsTracker.configuration.tap { |c| c.dsn = dsn; c.environment = "production"; c.logger = nil }
      ForgeOpsTracker.instance_variable_set(
        :@error_subscriber, ForgeOpsTracker::ErrorSubscriber.new(ForgeOpsTracker.configuration, delivery_queue: delivery_queue)
      )
    end

    it "reports through the same ErrorSubscriber Rails.error uses, with the given context" do
      error = begin
        raise ArgumentError, "card declined"
      rescue ArgumentError => e
        e
      end

      expect(ForgeOpsTracker.capture_exception(error, context: { order_id: 7 })).to be_nil

      expect(delivery_queue).to have_received(:push) do |payload|
        expect(payload[:exception_class]).to eq("ArgumentError")
        expect(payload[:message]).to eq("card declined")
        expect(payload[:context]).to eq(order_id: 7)
        expect(payload[:environment]).to eq("production")
      end
    end

    it "is a no-op that warns once when the environment isn't enabled" do
      ForgeOpsTracker.configuration.environment = "development"

      expect do
        ForgeOpsTracker.capture_exception(RuntimeError.new("one"))
        ForgeOpsTracker.capture_exception(RuntimeError.new("two"))
      end.to output("#{warning}\n").to_stderr
      expect(delivery_queue).not_to have_received(:push)
    end
  end

  describe ForgeOpsTracker::Middleware::RequestContext do
    let(:delivery_queue) { instance_double(ForgeOpsTracker::DeliveryQueue, push: true) }

    before do
      ForgeOpsTracker.configuration.tap { |c| c.dsn = dsn; c.environment = "production"; c.logger = nil }
      ForgeOpsTracker.instance_variable_set(
        :@error_subscriber, ForgeOpsTracker::ErrorSubscriber.new(ForgeOpsTracker.configuration, delivery_queue: delivery_queue)
      )
    end

    def rack_app(report_exceptions: nil, &endpoint)
      options = report_exceptions.nil? ? {} : { report_exceptions: report_exceptions }
      Rack::Builder.new do
        use ForgeOpsTracker::Middleware::RequestContext, **options
        run endpoint
      end.to_app
    end

    it "reports an exception escaping a plain Rack app, with the request's trace id, then re-raises it" do
      seen_trace_id = nil
      app = rack_app do |_env|
        seen_trace_id = ForgeOpsTracker::Middleware::RequestContext.current.trace_id
        raise ArgumentError, "card declined"
      end

      expect { Rack::MockRequest.new(app).post("/checkout") }.to raise_error(ArgumentError, "card declined")

      expect(delivery_queue).to have_received(:push).once do |payload|
        expect(payload[:exception_class]).to eq("ArgumentError")
        expect(payload[:context]).to eq("path" => "/checkout", "method" => "POST")
        expect(payload[:trace_id]).to eq(seen_trace_id)
      end
    end

    it "reports a Sinatra-style error the app turned into a 500 itself" do
      app = rack_app do |env|
        env["sinatra.error"] = RuntimeError.new("handled by the framework")
        [ 500, {}, [ "Internal Server Error" ] ]
      end

      response = Rack::MockRequest.new(app).get("/orders")

      expect(response.status).to eq(500)
      expect(delivery_queue).to have_received(:push).once do |payload|
        expect(payload[:message]).to eq("handled by the framework")
      end
    end

    it "doesn't report a framework error behind a non-5xx response (a Sinatra 404)" do
      app = rack_app do |env|
        env["sinatra.error"] = RuntimeError.new("not found")
        [ 404, {}, [ "Not Found" ] ]
      end

      Rack::MockRequest.new(app).get("/missing")

      expect(delivery_queue).not_to have_received(:push)
    end

    it "doesn't report a successful request" do
      Rack::MockRequest.new(rack_app { |_env| [ 200, {}, [ "ok" ] ] }).get("/")

      expect(delivery_queue).not_to have_received(:push)
    end

    it "only re-raises with report_exceptions: false, which is how the Railtie installs it" do
      app = rack_app(report_exceptions: false) { |_env| raise ArgumentError, "Rails.error reports this" }

      expect { Rack::MockRequest.new(app).get("/") }.to raise_error(ArgumentError)
      expect(delivery_queue).not_to have_received(:push)
    end
  end

  describe "a fresh ruby process" do
    around do |example|
      @received = Queue.new
      server = WEBrick::HTTPServer.new(Port: 0, BindAddress: "127.0.0.1", Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
      server.mount_proc("/") do |req, res|
        @received << [ req.path, req.body ]
        res.status = 202
      end
      thread = Thread.new { server.start }
      sleep 0.05 until server.status == :Running
      @port = server.config[:Port]
      example.run
    ensure
      server&.shutdown
      thread&.join
    end

    def run_child(script, extra_env = {})
      env = ENV.to_h.reject { |name, _| name.start_with?("FORGE_OPS_") || %w[RAILS_ENV RACK_ENV].include?(name) }
      env.merge!("FORGE_OPS_DSN" => "http://key@127.0.0.1:#{@port}/api/v1/events").merge!(extra_env)
      lib = File.expand_path("../../lib", __dir__)
      Open3.capture3(env, RbConfig.ruby, "-I", lib, "-e", script, unsetenv_others: true)
    end

    def events
      received = []
      received << @received.pop until @received.empty?
      received.select { |path, _| path == "/api/v1/events" }.map { |_, body| JSON.parse(body) }
    end

    let(:capture_script) do
      <<~RUBY
        require "forge_ops_tracker"
        ForgeOpsTracker.configure { |config| config.detect_changes = false }
        begin
          raise "first error from a new customer"
        rescue => e
          ForgeOpsTracker.capture_exception(e)
        end
      RUBY
    end

    it "with only a DSN set, delivers the error" do
      _stdout, stderr, status = run_child(capture_script)

      expect(status).to be_success, stderr
      expect(stderr).not_to include("[ForgeOps]")
      delivered = events
      expect(delivered.map { |e| e["message"] }).to eq([ "first error from a new customer" ])
      expect(delivered.first["environment"]).to eq("production")
    end

    it "with only a DSN set, delivers an error escaping a plain Rack app" do
      script = <<~RUBY
        require "forge_ops_tracker"
        require "rack"
        require "rack/mock"
        ForgeOpsTracker.configure { |config| config.detect_changes = false }
        app = Rack::Builder.new do
          use ForgeOpsTracker::Middleware::RequestContext
          run ->(env) { raise "boom from a Rack app" }
        end.to_app
        begin
          Rack::MockRequest.new(app).get("/")
        rescue RuntimeError
        end
      RUBY

      _stdout, stderr, status = run_child(script)

      expect(status).to be_success, stderr
      expect(events.map { |e| e["message"] }).to eq([ "boom from a Rack app" ])
    end

    it "in an explicit development environment, sends nothing and warns once" do
      script = capture_script + "ForgeOpsTracker.capture_exception(RuntimeError.new(\"again\"))\n"

      _stdout, stderr, status = run_child(script, "FORGE_OPS_ENVIRONMENT" => "development")

      expect(status).to be_success, stderr
      expect(stderr.scan("[ForgeOps] Not sending").size).to eq(1)
      expect(stderr).to include('this environment is "development"')
      expect(events).to be_empty
    end
  end
end
