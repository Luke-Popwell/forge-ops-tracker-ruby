require "spec_helper"

RSpec.describe ForgeOpsTracker::DeliveryStatus do
  it "reads a 2xx as delivered, a 4xx as rejected, and 408, 429 and 5xx as failed for now" do
    expect([ 200, 202, 204 ].map { |code| described_class.for_code(code) }.uniq).to eq([ :delivered ])
    expect([ 400, 401, 403, 404, 413, 422 ].map { |code| described_class.for_code(code) }.uniq).to eq([ :rejected ])
    expect([ 408, 429, 500, 502, 503, 301 ].map { |code| described_class.for_code(code) }.uniq).to eq([ :failed ])
  end

  it "reads a plain true/false from an injected client the way the old contract did" do
    expect(described_class.from(true)).to eq(:delivered)
    expect(described_class.from(false)).to eq(:failed)
    expect(described_class.from(nil)).to eq(:failed)
    expect(described_class.from(:rejected)).to eq(:rejected)
  end
end

RSpec.describe ForgeOpsTracker::FlushOutcome do
  let(:logged) { [] }
  let(:configuration) do
    messages = logged
    logger = Object.new
    logger.define_singleton_method(:debug) { |&message| messages << message.call }
    ForgeOpsTracker::Configuration.new.tap { |c| c.logger = logger }
  end

  subject(:outcome) { described_class.new(configuration, "metrics") }

  it "releases a delivered batch without a word" do
    expect(outcome.release?(:delivered)).to be true
    expect(logged).to be_empty
  end

  it "releases a rejected batch and says once what was dropped and why" do
    expect(outcome.release?(:rejected)).to be true
    expect(logged).to eq([ "[ForgeOpsTracker] dropping buffered metrics: the server rejected them and will not accept a retry" ])
  end

  it "keeps a batch through four failed flushes and releases it on the fifth" do
    expect(4.times.map { outcome.release?(:failed) }).to eq([ false, false, false, false ])
    expect(logged).to be_empty

    expect(outcome.release?(:failed)).to be true
    expect(logged).to eq([ "[ForgeOpsTracker] dropping buffered metrics: 5 flushes in a row failed" ])
  end

  it "never raises without a logger" do
    quiet = described_class.new(ForgeOpsTracker::Configuration.new, "metrics")

    expect { 5.times { quiet.release?(:failed) } }.not_to raise_error
    expect(quiet.release?(:rejected)).to be true
  end
end
