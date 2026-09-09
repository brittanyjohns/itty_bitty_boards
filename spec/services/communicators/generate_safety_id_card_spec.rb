# frozen_string_literal: true

require "rails_helper"

# No Chrome in CI, so both renderers are stubbed and these assert against the
# HTML the card is built from. ApplicationController.render is deliberately NOT
# stubbed — an ERB typo fails here rather than on a laminated card.
RSpec.describe Communicators::GenerateSafetyIdCard do
  let(:user) { create(:user) }
  let(:account) { create(:child_account, user: user, owner: user, name: "Rosa") }
  let(:profile) do
    Profile.create!(profileable: account,
                    username: "card-#{SecureRandom.hex(2)}",
                    slug: "card-#{SecureRandom.hex(2)}")
  end

  # The PNG and the PDF are rendered from ONE html string, so the first capture
  # is the document either way.
  def render_html
    captured = nil
    allow(HtmlToPng).to receive(:call) do |html:, **_opts|
      captured ||= html
      "\x89PNG-stub"
    end
    allow(Grover).to receive(:new) do |html, **_opts|
      captured ||= html
      instance_double(Grover, to_pdf: "%PDF-stub")
    end

    described_class.call(profile.reload, regenerate: true)
    captured
  end

  describe "the medical grid" do
    # The default state, not an edge case: the MySpeak wizard collected none of
    # these until #891, so this is the card most communicators get.
    it "prints no negative finding for a field nobody answered" do
      profile.update!(settings: { "emergency_notes" => "zznotezz" })

      html = render_html

      expect(html).not_to include("None listed")
      expect(html).not_to include("None")
    end

    # The distinction the care plan kept a muted line to preserve: an
    # unanswered field is not a child with no allergies.
    it "names the unanswered fields in one muted line" do
      profile.update!(settings: { "allergies" => "zzpeanutszz" })

      html = render_html

      expect(html).to include("zzpeanutszz")
      expect(html).to include("No conditions, medications, or other conditions were provided.")
    end

    it "drops the muted line when every medical field is answered" do
      profile.update!(settings: Profile::MEDICAL_SETTING_KEYS.index_with { |k| "zz#{k}zz" })

      html = render_html

      Profile::MEDICAL_SETTING_KEYS.each { |key| expect(html).to include("zz#{key}zz") }
      expect(html).not_to include("were provided")
    end

    # emergency_notes is not in the medical set: the card prints an instruction
    # when it is blank, so reporting "notes" as unanswered would be false.
    it "never names notes as unanswered" do
      profile.update!(settings: { "allergies" => "zzpeanutszz" })

      html = render_html

      expect(html).to include("Please call my emergency contacts.")
      expect(html).not_to include("or notes were provided")
    end

    it "renders one block per answered field, keeping its accent colour" do
      profile.update!(settings: { "allergies" => "zzpeanutszz", "medications" => "zzmelatoninzz" })

      html = render_html

      expect(html.scan("#7c3aed").length).to be >= 1
      expect(html.scan("#0f766e").length).to be >= 1
      # The two omitted blocks take their colours with them.
      expect(html).not_to include("#2563eb")
      expect(html).not_to include("#ea580c")
    end
  end
end
