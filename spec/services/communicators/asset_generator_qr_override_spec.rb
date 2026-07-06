require "rails_helper"

# The AAC Classroom Kit reuses the per-communicator asset generators but points
# their QR at the /classroom funnel instead of the sample profile's public page.
RSpec.describe "Communicator asset generators — qr_target_url override" do
  let(:child) { create(:child_account) }
  let(:profile) { child.create_profile! }
  let(:kit_url) { "https://speakanyway.com/classroom?utm_content=safety_tag" }

  before do
    # Avoid real headless-Chrome renders.
    allow_any_instance_of(Communicators::BaseAssetGenerator)
      .to receive(:generate_png_from_html).and_return("png-bytes")
    allow_any_instance_of(Communicators::BaseAssetGenerator)
      .to receive(:generate_pdf_from_html).and_return("pdf-bytes")
  end

  describe Communicators::GenerateDeviceTag do
    it "points the QR at the override when given" do
      expect_any_instance_of(described_class)
        .to receive(:qr_data_url_for).with(kit_url).and_return("data:image/png;base64,x")

      described_class.call(profile, qr_target_url: kit_url)
    end

    it "defaults the QR to the profile's public page when no override is given" do
      expect_any_instance_of(described_class)
        .to receive(:qr_data_url_for).with(profile.public_url).and_return("data:image/png;base64,x")

      described_class.call(profile)
    end
  end

  describe Communicators::GenerateSafetyIdCard do
    it "points the QR at the override when given" do
      expect_any_instance_of(described_class)
        .to receive(:qr_data_url_for).with(kit_url).and_return("data:image/png;base64,x")

      described_class.call(profile, qr_target_url: kit_url)
    end
  end

  it "folds the override into the freshness signature so tags re-render for a new QR target" do
    generator = Communicators::GenerateDeviceTag.new(profile, qr_target_url: kit_url)
    base = profile.safety_info_signature

    expect(generator.send(:asset_signature, base)).to include(base)
    expect(generator.send(:asset_signature, base)).to include("qr=#{kit_url}")

    plain = Communicators::GenerateDeviceTag.new(profile)
    expect(plain.send(:asset_signature, base)).to eq(base)
  end
end
