require_relative "lib/forge_ops_tracker/version"

Gem::Specification.new do |spec|
  spec.name = "forge_ops_tracker"
  spec.version = ForgeOpsTracker::VERSION
  spec.authors = [ "ForgeOps" ]
  spec.summary = "Rails exception reporting client for ForgeOps"
  spec.description = "Hooks Rails' error reporter and reports exceptions to ForgeOps " \
    "over HTTP, without ever raising back into the host application."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.homepage = "https://getforgeops.net"
  spec.metadata = {
    "homepage_uri" => spec.homepage,
    # Requires any account pushing a new version of this gem to have MFA enabled on RubyGems.org:
    # this is a security-adjacent client (it handles a host app's own exception backtraces,
    # potentially including request/user context), so the bar for who can publish a new version
    # under this name should be higher than the RubyGems default of none at all.
    "rubygems_mfa_required" => "true",
    # The public read-only mirror of this directory (see script/release_sdks_lib/mirror.rb).
    "source_code_uri" => "https://github.com/Luke-Popwell/forge-ops-tracker-ruby",
    "changelog_uri" => "https://github.com/Luke-Popwell/forge-ops-tracker-ruby/blob/main/CHANGELOG.md"
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = [ "lib" ]

  spec.add_development_dependency "rspec", "~> 3.13"
  # Neither is a runtime dependency of the gem itself (see Railtie: each integration only ever
  # loads if the corresponding library is already present in the host app, checked via defined?),
  # but the test suite needs the real thing to exercise real APIs against (Sidekiq's own
  # server-middleware contract, Puma's own Puma.stats_hash), the same reasoning e.g. the Java SDK
  # has a provided-scope spring-webmvc dependency for. Solid Queue isn't here for the same reason,
  # despite having its own integration too: SolidQueue::Engine subclasses Rails::Engine at the top
  # of that gem, so it can't even be required without Rails itself already loaded (confirmed
  # directly); adding rails as a dependency just for that would be a lot of weight for no real
  # gain, since the Solid Queue integration's own spec doesn't need anything solid_queue-internal
  # beyond a handful of class/method names, which it stubs directly instead (see that spec's own
  # comment).
  spec.add_development_dependency "sidekiq", "~> 8.1"
  spec.add_development_dependency "puma", "~> 6.0"
  # A real local HTTP server for the Net::HTTP integration's own spec (a real round trip is what
  # actually proves Module#prepend + super still behaves like the real method, not a stubbed one);
  # no longer part of Ruby's own standard library as of 3.0, needs its own gem now.
  spec.add_development_dependency "webrick", "~> 1.8"
  # Same reasoning as sidekiq/puma above: dev-only, since Integrations::RedisClientTiming only
  # ever prepends onto RedisClient if the host app already has it loaded (see Railtie's own
  # defined? guard), but that integration's own spec needs the real class to exercise a real
  # round trip against, the same "prepend a module, don't replace the method" reasoning
  # net_http_spec.rb's own real WEBrick server already documents.
  spec.add_development_dependency "redis-client", "~> 0.30"
  # Rack::MockRequest/Rack::Builder for the plain-Rack (non-Rails) reporting specs. Already in the
  # bundle through sidekiq; named here so those specs don't depend on that.
  spec.add_development_dependency "rack", ">= 2.2"
end
