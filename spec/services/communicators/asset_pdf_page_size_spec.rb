require "rails_helper"

# The safety ID card is fixed 1200x1800px art. Rendering its PDF onto a paper
# format (A4) clipped the width and spilled the card onto a second page — the
# PDF page must be sized to the card itself and stay a single page.
RSpec.describe Communicators::BaseAssetGenerator, "#generate_pdf_from_html" do
  # The method never touches the profile, so no persisted records are needed.
  let(:generator) { Communicators::GenerateSafetyIdCard.new(nil) }

  it "sizes the PDF page to the rendered card instead of a paper format" do
    fake_grover = instance_double(Grover, to_pdf: "%PDF-fake")
    captured_opts = nil

    expect(Grover).to receive(:new) do |_html, **opts|
      captured_opts = opts
      fake_grover
    end

    pdf = generator.send(:generate_pdf_from_html, "<html></html>", width: 1200, height: 1800)

    expect(pdf).to eq("%PDF-fake")
    expect(captured_opts[:width]).to eq("1200px")
    expect(captured_opts[:height]).to eq("1800px")
    expect(captured_opts[:viewport]).to eq(width: 1200, height: 1800)
    expect(captured_opts).not_to have_key(:format)
    expect(captured_opts[:print_background]).to be(true)
  end
end
