require "thread"

module ForgeOpsTracker
  # Tells ForgeOps what this process sees at startup (the Ruby version, the locked gem versions, the
  # current Active Record migration version, and optionally the names of its environment variables),
  # once per process, from a background thread. The server diffs it against the last snapshot for
  # the same project and environment and records whatever changed as a change, so this gem stays
  # stateless: it never remembers what it sent last time.
  #
  # Any key that can't be determined reliably is left out rather than guessed at, since the server
  # reads a missing key as "unknown", never as "everything was removed".
  class ChangeSnapshot
    MAX_DEPENDENCIES = 3000
    MAX_NAME_LENGTH = 200
    MAX_VERSION_LENGTH = 100
    MAX_ENV_VAR_NAMES = 3000

    # Host-specific variables that differ from one box to the next (or one boot to the next) without
    # anything about the deploy having changed, so a fleet doesn't look like it's changing on every
    # restart. The gem's own FORGE_OPS_* settings are dropped too.
    ENV_VAR_DENYLIST = %w[
      HOSTNAME HOST HOME PATH PWD OLDPWD SHLVL _ TERM USER LOGNAME SHELL LANG TMPDIR TZ PORT DYNO
      INVOCATION_ID JOURNAL_STREAM
    ].freeze
    ENV_VAR_DENYLIST_PATTERNS = [
      /\ALC_/, /\ASYSTEMD_/, /\AMEMORY_PRESSURE_/, /\AKUBERNETES_/, /\AFORGE_OPS_/,
      /_SERVICE_HOST\z/, /_SERVICE_PORT/, /_PORT_.*_TCP/
    ].freeze

    MUTEX = Mutex.new

    class << self
      # Starts the one snapshot this process sends, on its own thread so it never delays boot. A
      # second call is a no-op, so the Railtie and a plain ForgeOpsTracker.configure can't both
      # send one. Does nothing (and doesn't use up the once) when the gem isn't enabled or
      # detect_changes is off. Never raises.
      def start(configuration)
        return false unless configuration.enabled? && configuration.detect_changes

        MUTEX.synchronize do
          return false if @started

          @started = true
        end

        thread = Thread.new { new(configuration).deliver }
        thread.report_on_exception = false
        true
      rescue StandardError
        false
      end

      # Names only, never values, sorted so the same set always serializes the same way.
      def env_var_names(env = ENV)
        env.keys.reject { |name| denied_env_var?(name) }.sort.first(MAX_ENV_VAR_NAMES)
      end

      def denied_env_var?(name)
        ENV_VAR_DENYLIST.include?(name) || ENV_VAR_DENYLIST_PATTERNS.any? { |pattern| pattern.match?(name) }
      end
    end

    def initialize(configuration, client: Client.new(configuration))
      @configuration = configuration
      @client = client
    end

    def deliver
      DeliveryStatus.from(client.deliver_change_snapshot(payload)) == DeliveryStatus::DELIVERED
    rescue StandardError => e
      configuration.logger&.debug { "[ForgeOpsTracker] change snapshot failed: #{e.class}: #{e.message}" }
      false
    end

    def payload
      {
        environment: configuration.environment.to_s,
        state: {
          schema_version: schema_version,
          runtime: runtime,
          dependencies: dependencies,
          env_var_names: configuration.track_env_var_names ? self.class.env_var_names : nil
        }.compact
      }
    end

    def runtime
      "#{RUBY_ENGINE} #{RUBY_ENGINE_VERSION}"
    end

    # The app's Gemfile.lock (through Bundler, so it's the exact resolved versions), falling back to
    # whatever gems are actually activated when there's no bundle at all. nil, and so left out,
    # when neither is available.
    def dependencies
      specs = bundler_specs || Gem.loaded_specs.values
      return nil if specs.empty?

      specs.each_with_object({}) do |spec, deps|
        deps[spec.name.to_s[0, MAX_NAME_LENGTH]] = spec.version.to_s[0, MAX_VERSION_LENGTH]
      end.sort.first(MAX_DEPENDENCIES).to_h
    rescue StandardError
      nil
    end

    # The newest migration Active Record has run against this app's database, as a string. Left
    # out when Active Record isn't loaded, the database can't be reached, or nothing has been
    # migrated yet: a snapshot must never fail (or fail boot) because the database is down.
    def schema_version
      return nil unless defined?(::ActiveRecord::Base)

      version = ::ActiveRecord::Base.connection_pool.with_connection do |connection|
        pool = ::ActiveRecord::Base.connection_pool
        context = pool.respond_to?(:migration_context) ? pool.migration_context : connection.migration_context
        context.current_version
      end
      version.to_i.positive? ? version.to_s : nil
    rescue StandardError, ScriptError
      nil
    end

    private
      attr_reader :configuration, :client

      def bundler_specs
        return nil unless defined?(::Bundler)

        specs = ::Bundler.locked_gems&.specs
        specs.nil? || specs.empty? ? nil : specs
      rescue StandardError
        nil
      end
  end
end
