require "rails_helper"

RSpec.describe OauthCredential do
  describe ".upsert_refresh_token!" do
    it "creates the row and merges metadata on a re-seed" do
      described_class.upsert_refresh_token!(
        provider: "etsy", refresh_token: "one", metadata: { "shop_id" => "42" },
      )
      record = described_class.upsert_refresh_token!(
        provider: "etsy", refresh_token: "two", metadata: { "seeded_at" => "now" },
      )

      expect(described_class.count).to eq(1)
      expect(record.refresh_token).to eq("two")
      expect(record.metadata).to include("shop_id" => "42", "seeded_at" => "now")
    end

    it "drops the cached access token — a new grant invalidates the old one" do
      described_class.create!(
        provider: "etsy", refresh_token: "one",
        access_token: "cached", access_token_expires_at: 1.hour.from_now,
      )

      record = described_class.upsert_refresh_token!(provider: "etsy", refresh_token: "two")

      expect(record.access_token).to be_nil
      expect(record.access_token_expires_at).to be_nil
    end
  end

  describe "#access_token_valid?" do
    it "treats a token expiring within the skew window as already expired" do
      record = described_class.new(access_token: "t", access_token_expires_at: 10.seconds.from_now)
      expect(record.access_token_valid?).to be false
    end

    it "is true for a token comfortably in the future" do
      record = described_class.new(access_token: "t", access_token_expires_at: 1.hour.from_now)
      expect(record.access_token_valid?).to be true
    end
  end

  it "keeps tokens out of inspect output" do
    record = described_class.new(provider: "etsy", refresh_token: "super-secret", access_token: "also-secret")

    expect(record.inspect).not_to include("super-secret", "also-secret")
    expect(record.inspect).to include("etsy")
  end

  it "allows only one credential per provider" do
    described_class.create!(provider: "etsy", refresh_token: "a")

    expect { described_class.create!(provider: "etsy", refresh_token: "b") }
      .to raise_error(ActiveRecord::RecordInvalid)
  end
end
