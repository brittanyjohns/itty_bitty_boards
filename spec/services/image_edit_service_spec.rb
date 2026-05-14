require "rails_helper"

RSpec.describe ImageEditService, type: :service do
  describe "#edit_image_from_url" do
    let(:client) { double("openai_client") }
    subject(:service) { described_class.new(openai_client: client) }

    context "when staging" do
      before { allow(AppEnv).to receive(:staging?).and_return(true) }

      it "returns a placeholder data URL without touching OpenAI" do
        expect(client).not_to receive(:images)

        result = service.edit_image_from_url(image_url: "https://example.com/source.png", prompt: "make it nicer")

        expect(result).to start_with("data:image/jpeg;base64,")
        expect(result.split(",", 2).last).to be_present
      end

      it "still raises for missing args" do
        expect {
          service.edit_image_from_url(image_url: "", prompt: "x")
        }.to raise_error(ArgumentError)
      end
    end
  end
end
