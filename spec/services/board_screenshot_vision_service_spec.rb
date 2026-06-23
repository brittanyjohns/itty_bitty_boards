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

  describe "#parse_board normalization (non-staging)" do
    before do
      allow(AppEnv).to receive(:staging?).and_return(false)
      allow(File).to receive(:binread).and_return("fakebytes")
    end

    def stub_response(payload)
      allow(responses).to receive(:create).and_return({ "output_text" => payload.to_json })
    end

    it "fills label fallback, confidence and bg_color defaults" do
      stub_response(
        rows: 1, cols: 2,
        cells: [
          { row: 0, col: 0, label_raw: "Eat", label_norm: "eat", confidence: 0.8, bg_color: "white" },
          { row: 0, col: 1, label_raw: "Drink" }, # missing label_norm/confidence/bg_color
        ],
      )

      result = service.parse_board(image_path: "/tmp/x.png")

      expect(result[:rows]).to eq(1)
      expect(result[:cols]).to eq(2)
      first, second = result[:cells]
      expect(first[:label]).to eq("eat")
      expect(second[:label]).to eq("Drink")     # falls back to label_raw
      expect(second[:confidence]).to eq(0.0)
      expect(second[:bg_color]).to eq("")
    end

    it "overrides cols with the forced value even if the model returns a different count" do
      stub_response(rows: 2, cols: 9, cells: [{ row: 0, col: 0, label_raw: "hi", label_norm: "hi" }])
      result = service.parse_board(image_path: "/tmp/x.png", cols: 4)
      expect(result[:cols]).to eq(4)
    end

    it "computes confidence_avg from the cells when the model omits it" do
      stub_response(
        rows: 1, cols: 2,
        cells: [
          { row: 0, col: 0, label_raw: "a", confidence: 1.0 },
          { row: 0, col: 1, label_raw: "b", confidence: 0.0 },
        ],
      )
      result = service.parse_board(image_path: "/tmp/x.png")
      expect(result[:confidence_avg]).to eq(0.5)
    end

    it "raises when the Responses API returns no text" do
      allow(responses).to receive(:create).and_return({})
      expect { service.parse_board(image_path: "/tmp/x.png") }.to raise_error(/No output_text/)
    end
  end
end
