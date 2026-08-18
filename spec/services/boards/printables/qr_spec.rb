require "rails_helper"

RSpec.describe Boards::Printables::Qr do
  let(:board) { create(:board, name: "Core Words") }

  before { board.update_column(:slug, "core-words-starter-set-4f2a") }

  describe ".target_url_for" do
    it "points at the board's public page and carries nothing else" do
      expect(described_class.target_url_for(board))
        .to eq("https://app.speakanyway.com/pb/core-words-starter-set-4f2a")
    end
  end

  describe ".listing_target_url_for" do
    it "tags the marketplace surface the scan came from" do
      url = described_class.listing_target_url_for(board, content: "listing_video")

      expect(url).to start_with("#{described_class.target_url_for(board)}?")
      expect(url).to include("utm_source=etsy", "utm_medium=listing")
      expect(url).to include("utm_campaign=board_printable", "utm_content=listing_video")
    end
  end

  # The printed QR is the one with a physical size to lose. The bare URL is a
  # version-6 (41-module) code at the renderer's ECC, which is 0.5mm per module
  # on the 0.8in page header — already at the phone-camera detection floor that
  # made the kit tags unscannable once (2026-07-08, see
  # .claude-notes/marketing-assets.md). Tagging it pushes it to version 12
  # (65 modules, 0.31mm) and the code stops resolving on paper. Screen-only
  # slide QRs are exempt — they render at 244px+, where modules cost nothing.
  describe "scannability of the PRINTED code" do
    def version_of(url) = RQRCode::QRCode.new(url).qrcode.version

    it "keeps the printed URL as low-density as it is today" do
      expect(version_of(described_class.target_url_for(board))).to be <= 6
    end

    it "is why the campaign tags stay off it" do
      tagged = described_class.listing_target_url_for(board, content: "listing_image")

      expect(version_of(tagged)).to be > 4
    end
  end

  # Same URL, two jobs: paper keeps rqrcode's :h damage redundancy, a slide
  # trades it for modules because it is read off a clean screen and its URL is
  # ~90 characters longer.
  describe "ECC" do
    it "renders the screen code with fewer modules than :h would" do
      tagged = described_class.listing_target_url_for(board, content: "listing_video")

      screen = RQRCode::QRCode.new(tagged, level: described_class::SCREEN_ECC).qrcode
      print_ecc = RQRCode::QRCode.new(tagged, level: described_class::PRINT_ECC).qrcode

      expect(screen.module_count).to be < print_ecc.module_count
    end
  end

  describe ".data_url_for" do
    it "renders a white-backed PNG data URL" do
      data_url = described_class.data_url_for(described_class.target_url_for(board))

      expect(data_url).to start_with("data:image/png;base64,")
      png = ChunkyPNG::Image.from_blob(Base64.strict_decode64(data_url.split(",", 2).last))
      expect(png.width).to eq(described_class::SIZE)
    end
  end
end
