require "rails_helper"

RSpec.describe MenuVisionService, type: :service do
  let(:responses) { double("responses") }
  let(:client) { double("openai_client", responses: responses) }
  subject(:service) { described_class.new(openai_client: client) }

  describe "#extract_menu_items" do
    it "raises ArgumentError when image_url is blank" do
      expect { service.extract_menu_items(image_url: "") }
        .to raise_error(ArgumentError)
    end

    it "parses menu items from the vision response" do
      json = {
        menu_items: [
          { name: "cheeseburger", description: "With fries.",
            image_description: "A cheeseburger with fries." },
          { name: "milk" },
        ],
      }.to_json
      allow(responses).to receive(:create).and_return({ "output_text" => json })

      result = service.extract_menu_items(image_url: "https://example.com/menu.jpg")

      expect(result["menu_items"].size).to eq(2)
      expect(result["menu_items"].first).to eq(
        "name" => "cheeseburger",
        "description" => "With fries.",
        "image_description" => "A cheeseburger with fries.",
      )
      expect(result["menu_items"].last).to eq("name" => "milk")
    end

    it "reads the Responses API output-array payload shape" do
      json = { menu_items: [{ name: "soup" }] }.to_json
      payload = {
        "output" => [
          { "content" => [{ "type" => "output_text", "text" => json }] },
        ],
      }
      allow(responses).to receive(:create).and_return(payload)

      result = service.extract_menu_items(image_url: "https://example.com/menu.jpg")

      expect(result["menu_items"]).to eq([{ "name" => "soup" }])
    end

    it "drops items with a blank name" do
      json = { menu_items: [{ name: "" }, { name: "  " }, { name: "fries" }] }.to_json
      allow(responses).to receive(:create).and_return({ "output_text" => json })

      result = service.extract_menu_items(image_url: "https://example.com/menu.jpg")

      expect(result["menu_items"]).to eq([{ "name" => "fries" }])
    end

    it "returns an empty list when the menu has no items" do
      allow(responses).to receive(:create)
        .and_return({ "output_text" => { menu_items: [] }.to_json })

      result = service.extract_menu_items(image_url: "https://example.com/menu.jpg")

      expect(result).to eq("menu_items" => [])
    end

    it "raises when the response has no output text" do
      allow(responses).to receive(:create).and_return({})

      expect { service.extract_menu_items(image_url: "https://example.com/menu.jpg") }
        .to raise_error(/No output_text/)
    end
  end
end
