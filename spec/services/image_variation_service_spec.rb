require "rails_helper"

RSpec.describe ImageVariationService, type: :service do
  describe "#create_variation_from_url" do
    let(:client) { double("openai_client") }
    subject(:service) { described_class.new(openai_client: client) }

    context "when staging" do
      before { allow(AppEnv).to receive(:staging?).and_return(true) }

      it "returns the placeholder URL without touching OpenAI" do
        expect(client).not_to receive(:images)

        url = service.create_variation_from_url("https://example.com/source.png")

        expect(url).to start_with("https://")
        expect(url).to end_with("/placeholder.jpeg")
      end

      it "still returns nil for a blank url" do
        expect(service.create_variation_from_url("")).to be_nil
      end
    end
  end
end
