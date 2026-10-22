require "spec_helper"

RSpec.describe ForgeOpsTracker::PiiScrubber do
  describe ".scrub" do
    it "redacts an email address embedded in free text" do
      expect(described_class.scrub("undefined method 'name' for user@example.com"))
        .to eq("undefined method 'name' for [EMAIL FILTERED]")
    end

    it "redacts a formatted credit card number but leaves an ordinary long numeric id alone" do
      expect(described_class.scrub("card 4111-1111-1111-1111 declined")).to eq("card [CREDIT CARD FILTERED] declined")
      expect(described_class.scrub("Couldn't find Invoice with 'id'=8821445199")).to eq("Couldn't find Invoice with 'id'=8821445199")
    end

    it "redacts known API key and token formats" do
      expect(described_class.scrub("using sk_live_" + "4eC39HqLyjWDarjtT1zdp7dc")).to eq("using [STRIPE KEY FILTERED]")
      expect(described_class.scrub("Authorization: Bearer abc123.def456")).to eq("Authorization: [BEARER TOKEN FILTERED]")
    end

    it "redacts the whole value under a sensitive-looking key regardless of type or casing" do
      scrubbed = described_class.scrub({ "password" => "hunter2", "API-Key" => "sk_live_abc", "count" => 3 })

      expect(scrubbed).to eq("password" => "[FILTERED]", "API-Key" => "[FILTERED]", "count" => 3)
    end

    it "recurses into nested hashes and arrays" do
      scrubbed = described_class.scrub({ "user" => { "email" => "ada@example.com" }, "notes" => [ "no PII here" ] })

      expect(scrubbed).to eq("user" => { "email" => "[EMAIL FILTERED]" }, "notes" => [ "no PII here" ])
    end
  end
end
