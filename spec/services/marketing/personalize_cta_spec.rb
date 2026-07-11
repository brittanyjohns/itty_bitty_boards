require "rails_helper"

# The generic kit tag sheets carry a sheet-margin CTA pointing the printing
# adult at the free-account personalized versions (name, photo, live MySpeak
# QR). The line lives in the cut-away margin, not on the cut-out tags, and the
# URL is printed text — never folded into the QR (see qr_scannability_spec).
RSpec.describe "Marketing tag sheets — personalize CTA" do
  let(:rendered_html) { [] }

  before do
    fake_grover = instance_double(Grover, to_pdf: "%PDF-fake")
    allow(Grover).to receive(:new) do |html, **_opts|
      rendered_html << html
      fake_grover
    end
  end

  [Marketing::SafetyTagSheet, Marketing::DeviceTagSheet, Marketing::NameTagSheet].each do |sheet_class|
    it "#{sheet_class.name.demodulize} includes the free-account personalization line" do
      sheet_class.new.to_pdf

      expect(rendered_html.last).to include("free account at speakanyway.com")
      expect(rendered_html.last).to include("MySpeak")
    end
  end
end
