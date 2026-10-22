require "spec_helper"

RSpec.describe ForgeOpsTracker::PeriodicPoller do
  def wait_until(timeout: 2)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.01
    end
  end

  it "calls the block on its own after the configured interval" do
    calls = Queue.new

    ForgeOpsTracker::PeriodicPoller.start(0.02) { calls << :tick }

    expect(wait_until { !calls.empty? }).to be true
  end

  it "keeps ticking after the block raises, instead of dying silently" do
    calls = Queue.new
    attempt = 0

    ForgeOpsTracker::PeriodicPoller.start(0.02) do
      attempt += 1
      raise "boom" if attempt == 1
      calls << :tick
    end

    expect(wait_until { !calls.empty? }).to be true
  end

  it "logs, rather than raising, when the block errors" do
    logger = instance_double("Logger", debug: nil)
    calls = Queue.new

    ForgeOpsTracker::PeriodicPoller.start(0.02, logger: logger) do
      calls << :tick
      raise "boom"
    end

    expect(wait_until { !calls.empty? }).to be true
    sleep 0.05 # give the rescue a moment to actually run before asserting on it
    expect(logger).to have_received(:debug).at_least(:once)
  end
end
