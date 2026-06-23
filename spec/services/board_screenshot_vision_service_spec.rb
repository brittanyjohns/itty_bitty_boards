require "rails_helper"

RSpec.describe BoardScreenshotVisionService do
  subject(:service) { described_class.new(openai_client: client) }
  let(:responses) { double("responses") }
  let(:client)    { double("openai_client", responses: responses) }

  describe "#parse_board argument validation" do
    it "raises when image_path is blank" do
      expect { service.parse_board(image_path: "") }.to raise_error(ArgumentError)
    end

    it "raises when cols is not a positive integer" do
      expect { service.parse_board(image_path: "/tmp/x.png", cols: 0) }.to raise_error(ArgumentError)
    end
  end

  describe "staging short-circuit" do
    before { allow(AppEnv).to receive(:staging?).and_return(true) }

    it "returns a deterministic grid without calling OpenAI" do
      expect(responses).not_to receive(:create)

      result = service.parse_board(image_path: "/tmp/whatever.png")

      expect(result[:cells].size).to eq(result[:rows] * result[:cols])
      expect(result[:cells]).to all(include(:row, :col, :label_norm, :bg_color))
      expect(result[:confidence_avg]).to eq(1.0)
    end

    it "honors a forced column count" do
      result = service.parse_board(image_path: "/tmp/whatever.png", cols: 5)
      expect(result[:cols]).to eq(5)
      expect(result[:cells].size).to eq(result[:rows] * 5)
    end
  end
end
