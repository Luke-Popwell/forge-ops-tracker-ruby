require "spec_helper"
require "timeout"

RSpec.describe ForgeOpsTracker::ChangeSnapshot do
  let(:configuration) do
    ForgeOpsTracker::Configuration.new.tap do |config|
      config.dsn = "https://secret-key@tracker.example.com/api/v1/events"
      config.environment = "production"
    end
  end
  let(:client) { instance_double(ForgeOpsTracker::Client, deliver_change_snapshot: true) }

  subject(:snapshot) { described_class.new(configuration, client: client) }

  describe "#payload" do
    it "sends the configured environment and the Ruby runtime" do
      payload = snapshot.payload

      expect(payload[:environment]).to eq("production")
      expect(payload[:state][:runtime]).to eq("#{RUBY_ENGINE} #{RUBY_ENGINE_VERSION}")
    end

    it "sends dependencies as a flat name to version Hash of strings" do
      dependencies = snapshot.payload[:state][:dependencies]

      expect(dependencies).to be_a(Hash)
      expect(dependencies).to include("rspec-core")
      expect(dependencies.keys).to all(be_a(String))
      expect(dependencies.values).to all(be_a(String))
    end

    it "caps dependencies at 3000 entries" do
      specs = Array.new(3500) { |i| Gem::Specification.new(format("gem-%05d", i), "1.0.#{i}") }
      allow(Bundler).to receive(:locked_gems).and_return(instance_double(Bundler::LockfileParser, specs: specs))

      dependencies = snapshot.dependencies

      expect(dependencies.size).to eq(3000)
      expect(dependencies.keys.first).to eq("gem-00000")
    end

    it "truncates very long names and versions" do
      long_spec = Struct.new(:name, :version).new("z" * 500, "9" * 500)
      allow(Bundler).to receive(:locked_gems).and_return(instance_double(Bundler::LockfileParser, specs: [ long_spec ]))

      name, version = snapshot.dependencies.first

      expect(name.length).to eq(200)
      expect(version.length).to eq(100)
    end

    it "leaves dependencies out rather than guessing when nothing can be read" do
      allow(Bundler).to receive(:locked_gems).and_raise(RuntimeError, "no lockfile")
      allow(Gem).to receive(:loaded_specs).and_return({})

      expect(snapshot.payload[:state]).not_to have_key(:dependencies)
    end

    it "leaves schema_version out when Active Record isn't loaded" do
      expect(defined?(ActiveRecord::Base)).to be_nil
      expect(snapshot.payload[:state]).not_to have_key(:schema_version)
    end

    context "with Active Record loaded" do
      let(:context) { double("MigrationContext", current_version: 20_260_925_120_000) }
      let(:pool) { double("ConnectionPool", migration_context: context) }

      before do
        stub_const("ActiveRecord::Base", Class.new { def self.connection_pool; end })
        allow(ActiveRecord::Base).to receive(:connection_pool).and_return(pool)
        allow(pool).to receive(:with_connection) { |&block| block.call(double("Connection")) }
      end

      it "sends the current migration version as a string" do
        expect(snapshot.payload[:state][:schema_version]).to eq("20260925120000")
      end

      it "leaves it out when nothing has been migrated yet" do
        allow(context).to receive(:current_version).and_return(0)

        expect(snapshot.payload[:state]).not_to have_key(:schema_version)
      end

      it "leaves it out, without raising, when the database can't be reached" do
        allow(pool).to receive(:with_connection).and_raise(RuntimeError, "could not connect to server")

        expect { snapshot.payload }.not_to raise_error
        expect(snapshot.payload[:state]).not_to have_key(:schema_version)
        expect(snapshot.payload[:state][:runtime]).not_to be_nil
      end
    end

    it "leaves env_var_names out unless track_env_var_names is on" do
      expect(snapshot.payload[:state]).not_to have_key(:env_var_names)
    end

    it "sends env var names, never values, when track_env_var_names is on" do
      configuration.track_env_var_names = true
      stub_const("ENV", { "DATABASE_URL" => "postgres://secret", "HOSTNAME" => "web-1", "STRIPE_KEY" => "sk_live" })

      state = snapshot.payload[:state]

      expect(state[:env_var_names]).to eq(%w[DATABASE_URL STRIPE_KEY])
      expect(JSON.generate(state)).not_to include("secret", "sk_live", "web-1")
    end
  end

  describe ".env_var_names" do
    it "drops host-specific noise and the gem's own FORGE_OPS_* settings, keeping everything else sorted" do
      env = %w[
        HOSTNAME HOST HOME PATH PWD OLDPWD SHLVL _ TERM USER LOGNAME SHELL LANG LC_ALL LC_CTYPE TMPDIR TZ
        PORT DYNO INVOCATION_ID JOURNAL_STREAM SYSTEMD_EXEC_PID MEMORY_PRESSURE_WATCH KUBERNETES_SERVICE_HOST
        REDIS_SERVICE_HOST REDIS_SERVICE_PORT REDIS_SERVICE_PORT_HTTP REDIS_PORT_6379_TCP REDIS_PORT_6379_TCP_ADDR
        FORGE_OPS_DSN FORGE_OPS_RELEASE SECRET_KEY_BASE RAILS_ENV DATABASE_URL
      ].to_h { |name| [ name, "value" ] }

      expect(described_class.env_var_names(env)).to eq(%w[DATABASE_URL RAILS_ENV SECRET_KEY_BASE])
    end
  end

  describe "#deliver" do
    it "posts the payload through the client" do
      snapshot.deliver

      expect(client).to have_received(:deliver_change_snapshot).with(hash_including(environment: "production"))
    end

    it "never raises, even when building or posting the snapshot fails" do
      allow(client).to receive(:deliver_change_snapshot).and_raise(RuntimeError, "boom")

      expect { snapshot.deliver }.not_to raise_error
      expect(snapshot.deliver).to be false
    end
  end

  describe ".start" do
    let(:delivered) { Queue.new }

    before do
      allow(described_class).to receive(:start).and_call_original
      described_class.instance_variable_set(:@started, nil)
      allow(ForgeOpsTracker::Client).to receive(:new).and_return(client)
      allow(client).to receive(:deliver_change_snapshot) { |payload| delivered << payload; true }
    end

    after { described_class.instance_variable_set(:@started, nil) }

    it "sends one snapshot from a background thread" do
      expect(described_class.start(configuration)).to be true

      payload = Timeout.timeout(2) { delivered.pop }
      expect(payload[:state][:runtime]).to start_with(RUBY_ENGINE)
    end

    it "sends only once per process" do
      expect(described_class.start(configuration)).to be true
      expect(described_class.start(configuration)).to be false

      Timeout.timeout(2) { delivered.pop }
      sleep 0.05
      expect(delivered).to be_empty
    end

    it "sends nothing when detect_changes is off" do
      configuration.detect_changes = false

      expect(described_class.start(configuration)).to be false
      expect(ForgeOpsTracker::Client).not_to have_received(:new)
    end

    it "sends nothing when the gem isn't enabled, and doesn't use up the once" do
      configuration.environment = "development"
      expect(described_class.start(configuration)).to be false

      configuration.environment = "production"
      expect(described_class.start(configuration)).to be true
      Timeout.timeout(2) { delivered.pop }
    end
  end
end
