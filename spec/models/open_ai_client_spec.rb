require "rails_helper"

RSpec.describe OpenAiClient do
  describe "#create_image" do
    subject(:client) { described_class.new(prompt: "dog") }

    context "when staging" do
      before { allow(AppEnv).to receive(:staging?).and_return(true) }

      it "returns the placeholder image response without calling OpenAI" do
        expect(OpenAI::Client).not_to receive(:new)

        result = client.create_image

        expect(result[:model]).to eq("staging-placeholder")
        expect(result[:b64_json]).to be_present
        expect(result[:content_type]).to eq("image/jpeg")
        expect(result[:edited_prompt]).to eq("dog")
      end
    end

    context "when not staging" do
      before { allow(AppEnv).to receive(:staging?).and_return(false) }

      it "calls the OpenAI image generation API" do
        images = double("images")
        openai = instance_double(OpenAI::Client, images: images)
        allow(client).to receive(:openai_client).and_return(openai)

        expect(images).to receive(:generate).and_return(
          { "data" => [{ "b64_json" => "abc123", "revised_prompt" => "a dog" }] }
        )

        result = client.create_image
        expect(result[:b64_json]).to eq("abc123")
      end
    end
  end

  describe "#create_image_variation" do
    subject(:client) { described_class.new(prompt: "dog") }

    context "when staging" do
      before { allow(AppEnv).to receive(:staging?).and_return(true) }

      it "returns the placeholder image URL without calling OpenAI" do
        expect(OpenAI::Client).not_to receive(:new)

        url = client.create_image_variation("ignored")

        expect(url).to start_with("https://")
        expect(url).to end_with("/placeholder.jpeg")
      end
    end

    context "when not staging" do
      before { allow(AppEnv).to receive(:staging?).and_return(false) }

      it "calls the OpenAI image variations API" do
        images = double("images")
        openai = instance_double(OpenAI::Client, images: images)
        allow(client).to receive(:openai_client).and_return(openai)

        expect(images).to receive(:variations).and_return(
          { "data" => [{ "url" => "https://example.com/variation.png" }] }
        )

        expect(client.create_image_variation("ignored")).to eq("https://example.com/variation.png")
      end
    end
  end
end
