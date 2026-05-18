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

  describe "#generate_scenario_description" do
    subject(:client) { described_class.new({}) }

    def stub_chat_response(content)
      chat = double("chat")
      openai = instance_double(OpenAI::Client, chat: chat)
      allow(client).to receive(:openai_client).and_return(openai)
      allow(chat).to receive(:call).and_return(nil)
      # The real client does `openai_client.chat(parameters: ...)`. The
      # ruby-openai gem's #chat takes keyword args, so stub it on the
      # double.
      allow(openai).to receive(:chat).and_return({
        "choices" => [{ "message" => { "role" => "assistant", "content" => content } }],
      })
    end

    it "returns the stripped content for a successful response" do
      stub_chat_response("  Arriving at school. Meeting the teacher.  ")
      expect(client.generate_scenario_description("First day", "5-7"))
        .to eq("Arriving at school. Meeting the teacher.")
    end

    it "builds messages with an AAC system role and a factual user prompt" do
      openai = instance_double(OpenAI::Client)
      allow(client).to receive(:openai_client).and_return(openai)

      expect(openai).to receive(:chat) do |parameters:|
        expect(parameters[:model]).to eq(OpenAiClient::GTP_MODEL)
        msgs = parameters[:messages]
        expect(msgs.first[:role]).to eq("system")
        expect(msgs.first[:content]).to match(/AAC/i)
        expect(msgs.last[:role]).to eq("user")
        expect(msgs.last[:content]).to include("First day")
        expect(msgs.last[:content]).to include("5-7")
        expect(msgs.last[:content]).to match(/do not invent/i)
        # No JSON mode for prose output.
        expect(parameters[:response_format]).to be_nil
        { "choices" => [{ "message" => { "content" => "ok" } }] }
      end

      client.generate_scenario_description("First day", "5-7")
    end

    it "returns nil when the response is empty" do
      openai = instance_double(OpenAI::Client)
      allow(client).to receive(:openai_client).and_return(openai)
      allow(openai).to receive(:chat).and_return(nil)

      expect(client.generate_scenario_description("X", "1-3")).to be_nil
    end

    it "handles a missing age_range gracefully" do
      openai = instance_double(OpenAI::Client)
      allow(client).to receive(:openai_client).and_return(openai)
      expect(openai).to receive(:chat) do |parameters:|
        expect(parameters[:messages].last[:content]).to include("student who uses AAC")
        { "choices" => [{ "message" => { "content" => "ok" } }] }
      end

      client.generate_scenario_description("X", nil)
    end
  end
end
