require "rails_helper"

# AAC personalization fields (aac_level / vocab_type / age_band) stored in the
# details jsonb — typed accessors + validation against CommunicatorProfile's
# enums. No columns, no migration.
RSpec.describe ChildAccount, type: :model do
  let(:account) { FactoryBot.build(:child_account) }

  describe "typed accessors" do
    it "write into and read from details" do
      account.aac_level = "emerging"
      account.vocab_type = "core"
      account.age_band = "4-6"

      expect(account.details["aac_level"]).to eq("emerging")
      expect(account.aac_level).to eq("emerging")
      expect(account.vocab_type).to eq("core")
      expect(account.age_band).to eq("4-6")
    end

    it "preserve other details keys (interests pattern)" do
      account.details = { "interests" => ["trains"] }
      account.aac_level = "developing"
      expect(account.details["interests"]).to eq(["trains"])
    end
  end

  describe "validation" do
    it "accepts valid values and normalizes case/whitespace" do
      account.aac_level = " Emerging "
      expect(account).to be_valid
      expect(account.aac_level).to eq("emerging")
    end

    it "rejects an invalid aac_level" do
      account.aac_level = "wizard"
      expect(account).not_to be_valid
      expect(account.errors[:aac_level]).to be_present
    end

    it "rejects an invalid vocab_type and age_band" do
      account.vocab_type = "everything"
      account.age_band = "99-100"
      expect(account).not_to be_valid
      expect(account.errors[:vocab_type]).to be_present
      expect(account.errors[:age_band]).to be_present
    end

    it "allows clearing a field with nil/blank (key is dropped)" do
      account.aac_level = "emerging"
      account.aac_level = ""
      expect(account).to be_valid
      expect(account.details).not_to have_key("aac_level")
      expect(account.aac_level).to be_nil
    end

    it "validates wholesale details assignment too (the update controller path)" do
      account.details = { "aac_level" => "bogus" }
      expect(account).not_to be_valid
    end

    it "leaves accounts without profile fields untouched" do
      account.details = { "interests" => ["dinosaurs"] }
      expect(account).to be_valid
      expect(account.details).to eq({ "interests" => ["dinosaurs"] })
    end
  end
end
