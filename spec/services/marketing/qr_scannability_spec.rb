require "rails_helper"

# Regression guard for the "kit tag QRs won't scan" bug. The tags used to
# encode the ~119-char /classroom UTM URL, which forced a 41-module (version-6)
# QR even after ECC was dropped to :l to fit it — and at the tags' small printed
# size that fell at/below the ~0.5mm-per-module phone-camera detection floor, so
# the codes wouldn't scan at all. The fix is a SHORT target URL
# (speakanyway.com/myspeak, no UTM), which keeps the code a low-density
# version-2/3 and lets us run proper ECC :m damage redundancy again.
#
# These expectations pin BOTH levers the renderer controls: ECC level AND the
# resulting module density (QR version). Printed physical size is the third
# lever and lives in app/views/marketing/*_sheet.html.erb — if these start
# failing, re-check that a caller isn't passing a long (UTM-laden) URL, which
# is what re-inflates the version.
RSpec.describe "Marketing sheet QR scannability" do
  # The real kit target: short, no UTM, bare domain (brand print rule).
  let(:target_url) { "https://speakanyway.com/myspeak" }

  shared_examples "a scannable marketing QR" do
    it "encodes at ECC level :m (restored now that the URL is short)" do
      expect(RQRCode::QRCode).to receive(:new).with(target_url, level: :m).and_call_original
      data_url
    end

    it "stays a low-density (<= version 3 / 29-module) QR at the short URL" do
      # Density is what broke scanning. Version 3 at the tags' printed sizes is
      # ~0.9mm/module; a regression to a long URL would push this to v6 (41
      # modules, ~0.6mm) and this guard would trip.
      version = RQRCode::QRCode.new(target_url, level: :m).qrcode.version
      expect(version).to be <= 3
    end

    it "renders a 480px print-resolution PNG data URL" do
      expect(data_url).to start_with("data:image/png;base64,")
      png = ChunkyPNG::Image.from_blob(Base64.strict_decode64(data_url.split(",", 2).last))
      expect(png.width).to eq(480)
      expect(png.height).to eq(480)
    end

    it "returns nil for a blank URL" do
      expect(blank_data_url).to be_nil
    end
  end

  describe Marketing::SafetyTagSheet do
    subject(:sheet) { described_class.new(qr_target_url: target_url) }

    let(:data_url) { sheet.send(:qr_data_url, target_url) }
    let(:blank_data_url) { sheet.send(:qr_data_url, nil) }

    it_behaves_like "a scannable marketing QR"
  end

  describe Marketing::DeviceTagSheet do
    subject(:sheet) { described_class.new(qr_target_url: target_url) }

    let(:data_url) { sheet.send(:qr_data_url, target_url) }
    let(:blank_data_url) { sheet.send(:qr_data_url, nil) }

    it_behaves_like "a scannable marketing QR"
  end

  describe Marketing::NameTagSheet do
    subject(:sheet) { described_class.new(qr_target_url: target_url) }

    let(:data_url) { sheet.send(:qr_data_url, target_url) }
    let(:blank_data_url) { sheet.send(:qr_data_url, nil) }

    it_behaves_like "a scannable marketing QR"
  end
end
