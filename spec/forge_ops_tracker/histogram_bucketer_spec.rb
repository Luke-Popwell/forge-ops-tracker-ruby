require "spec_helper"

RSpec.describe ForgeOpsTracker::HistogramBucketer do
  describe ".bucket_for" do
    it "returns the smallest boundary a duration fits under, as a String" do
      expect(described_class.bucket_for(10)).to eq("50")
      expect(described_class.bucket_for(50)).to eq("50")
      expect(described_class.bucket_for(51)).to eq("100")
      expect(described_class.bucket_for(4999)).to eq("5000")
    end

    it "returns \"inf\" for anything larger than the largest boundary" do
      expect(described_class.bucket_for(10_001)).to eq("inf")
      expect(described_class.bucket_for(1_000_000)).to eq("inf")
    end

    it "puts a duration exactly on a boundary into that boundary's own bucket, not the next one up" do
      described_class::BOUNDARIES_MS.each do |boundary|
        expect(described_class.bucket_for(boundary)).to eq(boundary.to_s)
      end
    end
  end
end
