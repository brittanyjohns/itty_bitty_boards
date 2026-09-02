# frozen_string_literal: true

require "rails_helper"

# There is no Chrome in CI, so the two render calls are stubbed and these
# assert against the RENDERED HTML. ApplicationController.render is deliberately
# NOT stubbed, so an ERB or layout typo fails here rather than in production.
RSpec.describe Communicators::GenerateScanTag do
  let(:child) { create(:child_account) }
  let(:profile) { child.create_profile! }

  # The HTML both render calls were handed. One render feeds both, so capturing
  # either is capturing the document.
  let(:rendered) { [] }

  before do
    allow_any_instance_of(Communicators::BaseAssetGenerator)
      .to receive(:generate_png_from_html) { |_, html, **_opts| rendered << html; "png-bytes" }
    allow_any_instance_of(Communicators::BaseAssetGenerator)
      .to receive(:generate_pdf_from_html).and_return("pdf-bytes")
  end

  def html
    rendered.last
  end

  # ERB escapes what it interpolates, and the default line carries an
  # apostrophe — so a raw-string assertion never matches, and a raw-string
  # `not_to include` passes whether the line is there or not.
  def printed(text)
    ERB::Util.html_escape(text)
  end

  describe "the printed line" do
    it "prints the default line when the owner has stored nothing" do
      described_class.call(profile)

      expect(html).to include(printed(Profile::SCAN_TAG_DEFAULT_NOTE))
    end

    it "prints a stored note verbatim instead of the default" do
      profile.update!(settings: { "scan_tag_note" => "Please call my mum, Rosa." })

      described_class.call(profile)

      expect(html).to include(printed("Please call my mum, Rosa."))
      expect(html).not_to include(printed(Profile::SCAN_TAG_DEFAULT_NOTE))
    end

    it "falls back to the default when the stored note is blank" do
      profile.update!(settings: { "scan_tag_note" => "   " })

      described_class.call(profile)

      expect(html).to include(printed(Profile::SCAN_TAG_DEFAULT_NOTE))
    end

    # The whole reason there are two settings keys rather than one: a bare
    # string can't tell "never set" from "deliberately cleared".
    it "prints no line at all when the note is switched off" do
      profile.update!(settings: { "scan_tag_note_enabled" => false,
                                  "scan_tag_note" => "Please call my mum, Rosa." })

      described_class.call(profile)

      expect(html).not_to include(printed("Please call my mum, Rosa."))
      expect(html).not_to include(printed(Profile::SCAN_TAG_DEFAULT_NOTE))
    end

    it "still renders the QR when the note is switched off" do
      profile.update!(settings: { "scan_tag_note_enabled" => false })

      described_class.call(profile)

      expect(html).to include("data:image/png;base64,")
    end
  end

  describe "the QR target" do
    # Printed and clipped to a bag, so it has to survive the owner rotating
    # their public link. Same rule as the device tag.
    it "points at the profile's permanent page, not its public one" do
      expect(profile.permanent_url).not_to eq(profile.public_url)

      expect_any_instance_of(described_class)
        .to receive(:qr_data_url_for).with(profile.permanent_url).and_return("data:image/png;base64,x")

      described_class.call(profile)
    end

    it "honours a qr_target_url override" do
      kit_url = "https://speakanyway.com/classroom?utm_content=scan_tag"

      expect_any_instance_of(described_class)
        .to receive(:qr_data_url_for).with(kit_url).and_return("data:image/png;base64,x")

      described_class.call(profile, qr_target_url: kit_url)
    end
  end

  describe "attaching and freshness" do
    it "attaches both a PNG and a PDF stamped with the content signature" do
      described_class.call(profile)
      profile.reload

      expect(profile.scan_tag_png).to be_attached
      expect(profile.scan_tag_pdf).to be_attached
      expect(profile.scan_tag_png.filename.to_s).to eq("scan-tag-#{profile.id}.png")
      expect(profile.scan_tag_pdf.filename.to_s).to eq("scan-tag-#{profile.id}.pdf")
      expect(profile.scan_tag_png.metadata["signature"]).to eq(profile.safety_info_signature)
    end

    it "does not re-render when the attachments are already fresh" do
      described_class.call(profile)
      rendered.clear

      described_class.call(profile.reload)

      expect(rendered).to be_empty
    end

    it "re-renders when asked to regenerate" do
      described_class.call(profile)
      rendered.clear

      described_class.call(profile.reload, regenerate: true)

      expect(rendered.size).to eq(1)
    end

    # The note lives in `settings`, which safety_info_signature hashes — so
    # editing the line has to bust the cache with no extra wiring.
    it "re-renders when the note changes" do
      described_class.call(profile)
      rendered.clear

      profile.update!(settings: { "scan_tag_note" => "Call Rosa." })
      described_class.call(profile.reload)

      expect(html).to include(printed("Call Rosa."))
    end
  end
end
