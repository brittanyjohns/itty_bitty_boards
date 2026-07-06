require "rails_helper"

# Regression guard for the "kit tag QRs won't scan" bug: rqrcode's default
# ECC level (:h) turned the ~119-char /classroom UTM URL into a 57-module QR,
# which at the tags' small printed size fell below the ~0.5mm-per-module
# phone-camera detection floor. The sheets must encode at :l (41 modules) and
# render a print-resolution source PNG. If these expectations start failing,
# re-check the physical QR sizes in app/views/marketing/*_sheet.html.erb —
# module density is a joint property of ECC level AND printed size.
RSpec.describe "Marketing sheet QR scannability" do
  let(:long_url) do
    "https://speakanyway.com/classroom?utm_source=aac_kit&utm_medium=print&utm_campaign=classroom_kit&utm_content=safety_tag"
  end

  shared_examples "a scannable marketing QR" do
    it "encodes at ECC level :l (not rqrcode's dense :h default)" do
      expect(RQRCode::QRCode).to receive(:new).with(long_url, level: :l).and_call_original
      data_url
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
    subject(:sheet) { described_class.new(qr_target_url: long_url) }

    let(:data_url) { sheet.send(:qr_data_url, long_url) }
    let(:blank_data_url) { sheet.send(:qr_data_url, nil) }

    it_behaves_like "a scannable marketing QR"
  end

  describe Marketing::NameTagSheet do
    subject(:sheet) { described_class.new(qr_target_url: long_url) }

    let(:data_url) { sheet.send(:qr_data_url) }
    let(:blank_data_url) { described_class.new(qr_target_url: nil).send(:qr_data_url) }

    it_behaves_like "a scannable marketing QR"
  end
end
