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

  # Words Within Reach playground nominations ride the same table as download
  # leads, discriminated by source, with the campaign fields in `data`.
  describe "playground nominations" do
    include ActiveJob::TestHelper

    let(:nomination_data) do
      {
        "park" => "LaGrange Community Park",
        "city" => "LaGrange, OH",
        "role" => "Parent / caregiver",
        "why" => "Our son swings here every day.",
        "sponsor_interest" => "Yes",
      }
    end

    it "identifies a nomination by source" do
      expect(build(:download_lead, source: DownloadLead::NOMINATION_SOURCE)).to be_nomination
      expect(build(:download_lead, source: "free_download")).not_to be_nomination
    end

    it "scopes nominations away from other lead sources" do
      nomination = create(:download_lead, source: DownloadLead::NOMINATION_SOURCE, data: nomination_data)
      create(:download_lead, source: "free_download")

      expect(DownloadLead.nominations).to contain_exactly(nomination)
    end

    describe "#marketing_opt_in?" do
      it "is false when data carries no opt-in key" do
        expect(build(:download_lead, data: nomination_data)).not_to be_marketing_opt_in
      end

      it "is false when data is nil" do
        expect(build(:download_lead, data: nil)).not_to be_marketing_opt_in
      end

      it "reads falsey values as no consent" do
        ["false", "0", "", nil].each do |value|
          lead = build(:download_lead, data: nomination_data.merge("marketing_opt_in" => value))
          expect(lead.marketing_opt_in?).to eq(false), "expected #{value.inspect} to read as no consent"
        end
      end

      it "reads the values a checkbox actually sends as consent" do
        [true, "true", "1"].each do |value|
          lead = build(:download_lead, data: nomination_data.merge("marketing_opt_in" => value))
          expect(lead.marketing_opt_in?).to eq(true), "expected #{value.inspect} to read as consent"
        end
      end
    end

    describe "#sync_to_mailchimp?" do
      it "is false for a nomination without an opt-in" do
        lead = build(:download_lead, source: DownloadLead::NOMINATION_SOURCE, data: nomination_data)
        expect(lead.sync_to_mailchimp?).to eq(false)
      end

      it "is true for a nomination with an opt-in" do
        lead = build(
          :download_lead,
          source: DownloadLead::NOMINATION_SOURCE,
          data: nomination_data.merge("marketing_opt_in" => true),
        )
        expect(lead.sync_to_mailchimp?).to eq(true)
      end

      # Nominations are the only source that requires consent. Every funnel that
      # existed before this change must behave exactly as it did.
      it "is true for every non-nomination source, opt-in or not" do
        %w[free_download classroom_kit ctg etsy_landing].each do |source|
          expect(build(:download_lead, source: source).sync_to_mailchimp?).to eq(true)
        end
      end
    end

    describe "#nomination_field" do
      it "reads a string key from data given a symbol" do
        lead = build(:download_lead, data: nomination_data)
        expect(lead.nomination_field(:park)).to eq("LaGrange Community Park")
      end

      it "returns nil for a blank value, a missing key, or nil data" do
        lead = build(:download_lead, data: nomination_data.merge("city" => ""))
        expect(lead.nomination_field(:city)).to be_nil
        expect(lead.nomination_field(:nope)).to be_nil
        expect(build(:download_lead, data: nil).nomination_field(:park)).to be_nil
      end
    end

    describe "admin notification" do
      it "emails the admin when a nomination is created" do
        expect {
          create(:download_lead, source: DownloadLead::NOMINATION_SOURCE, data: nomination_data)
        }.to have_enqueued_mail(AdminMailer, :new_nomination_email)
      end

      it "does not email the admin for an ordinary download lead" do
        expect {
          create(:download_lead, source: "free_download")
        }.not_to have_enqueued_mail(AdminMailer, :new_nomination_email)
      end

      # A mail failure must never cost us the nomination itself.
      it "still saves the lead when the mailer raises" do
        allow(AdminMailer).to receive(:new_nomination_email).and_raise(StandardError, "smtp down")

        expect {
          create(:download_lead, source: DownloadLead::NOMINATION_SOURCE, data: nomination_data)
        }.to change(DownloadLead, :count).by(1)
      end
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
