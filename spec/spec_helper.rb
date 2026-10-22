$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "forge_ops_tracker"

# A bare stand-in for ForgeOpsTracker::Railtie, which this gem's own Rails-free test suite never
# loads for real (see PerformanceInstrumentation's own top comment for why): several integration
# specs (net_http_spec, integrations/redis_client_spec, middleware/span_tracing_spec) call methods
# their own module under test calls on Railtie directly (performance_flusher/failure_event_buffer/
# span_queue), safe in a real app since Railtie always exists there, and need something real here
# for their own `allow(...).to receive(...)` stubs to attach to. Defined once, centrally, with
# every method any of those specs needs, rather than each spec file defining its own narrower
# version: several independent `class Railtie; def self.foo; end; end unless defined?(...)` blocks
# scattered across spec files race on load order, since only the first one to run actually wins
# and the others silently skip re-opening it, leaving whichever methods THEY needed undefined.
module ForgeOpsTracker
  class Railtie
    def self.performance_flusher; end
    def self.failure_event_buffer; end
    def self.span_queue; end
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = "spec/examples.txt"
  config.disable_monkey_patching!

  # Outside Rails, ForgeOpsTracker.configure starts the startup ChangeSnapshot, which would post
  # from a background thread in every spec that configures an enabled DSN. Only
  # change_snapshot_spec.rb exercises the real thing (with HTTP stubbed); everything else gets this.
  config.before do
    allow(ForgeOpsTracker::ChangeSnapshot).to receive(:start).and_return(false)
  end
  config.order = :random
  Kernel.srand config.seed
end
