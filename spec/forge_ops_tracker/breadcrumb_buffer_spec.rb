require "spec_helper"

RSpec.describe ForgeOpsTracker::BreadcrumbBuffer do
  let(:configuration) { ForgeOpsTracker::Configuration.new.tap { |c| c.max_breadcrumbs = 3 } }
  subject(:buffer) { described_class.new(configuration) }

  it "returns entries in insertion order, each carrying the given fields plus a timestamp" do
    buffer.add(category: "query", message: "User Load", level: "info", data: { duration_ms: 1.2 })

    entry = buffer.all.first
    expect(entry[:category]).to eq("query")
    expect(entry[:message]).to eq("User Load")
    expect(entry[:level]).to eq("info")
    expect(entry[:data]).to eq(duration_ms: 1.2)
    expect(entry[:timestamp]).to be_present_iso8601
  end

  it "defaults level to info and data to an empty hash when not given" do
    buffer.add(category: "custom", message: "checkpoint")

    entry = buffer.all.first
    expect(entry[:level]).to eq("info")
    expect(entry[:data]).to eq({})
  end

  it "drops the oldest entry once max_breadcrumbs is exceeded" do
    4.times { |n| buffer.add(category: "custom", message: "entry #{n}") }

    expect(buffer.all.map { |e| e[:message] }).to eq([ "entry 1", "entry 2", "entry 3" ])
  end

  it "re-reads max_breadcrumbs on every add, not just at construction" do
    buffer.add(category: "custom", message: "one")
    buffer.add(category: "custom", message: "two")
    configuration.max_breadcrumbs = 1
    buffer.add(category: "custom", message: "three")

    expect(buffer.all.map { |e| e[:message] }).to eq([ "three" ])
  end

  it "adds nothing at all when max_breadcrumbs is 0" do
    configuration.max_breadcrumbs = 0

    buffer.add(category: "custom", message: "one")

    expect(buffer.all).to eq([])
  end

  it "#all returns a copy, not the internal array" do
    buffer.add(category: "custom", message: "one")

    snapshot = buffer.all
    snapshot << { category: "custom", message: "mutated externally" }

    expect(buffer.all.length).to eq(1)
  end
end
