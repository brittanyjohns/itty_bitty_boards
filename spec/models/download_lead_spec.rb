require "rails_helper"

RSpec.describe DownloadLead, type: :model do
  describe "validations" do
    it "is valid with a well-formed email" do
      lead = build(:download_lead, email: "person@example.com")
      expect(lead).to be_valid
    end

    it "is invalid without an email" do
      lead = build(:download_lead, email: nil)
      expect(lead).not_to be_valid
      expect(lead.errors[:email]).to be_present
    end

    it "is invalid with a malformed email" do
      lead = build(:download_lead, email: "not-an-email")
      expect(lead).not_to be_valid
      expect(lead.errors[:email]).to be_present
    end
  end

  describe "source default" do
    it "falls back to DEFAULT_SOURCE when source is blank" do
      lead = build(:download_lead, source: nil)
      lead.valid?
      expect(lead.source).to eq(DownloadLead::DEFAULT_SOURCE)
    end

    it "keeps an explicit source" do
      lead = build(:download_lead, source: "etsy_landing")
      lead.valid?
      expect(lead.source).to eq("etsy_landing")
    end
  end

  describe "board association" do
    it "is valid without a board (board_id can be nil)" do
      lead = build(:download_lead, board: nil)
      expect(lead).to be_valid
    end

    it "associates an optional board" do
      board = create(:board)
      lead = create(:download_lead, board: board)
      expect(lead.reload.board).to eq(board)
    end
  end
end
