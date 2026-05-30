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

  describe "language-aware prompts" do
    subject(:client) { described_class.new({}) }

    before { allow(client).to receive(:create_chat).and_return({ content: "{}" }) }

    def last_prompt
      client.instance_variable_get(:@messages).to_s
    end

    describe "#append_language_instruction" do
      it "appends the instruction for a supported non-English code" do
        expect(client.append_language_instruction("base", "es")).to eq("base Respond in Spanish.")
      end

      it "is a no-op for English" do
        expect(client.append_language_instruction("base", "en")).to eq("base")
      end

      it "is a no-op for blank or unknown codes" do
        expect(client.append_language_instruction("base", "")).to eq("base")
        expect(client.append_language_instruction("base", "xx")).to eq("base")
      end
    end

    describe "#get_word_suggestions" do
      it "instructs OpenAI to respond in the language for non-English" do
        client.get_word_suggestions("drink", 5, [], "default", language: "es")
        expect(last_prompt).to include("Respond in Spanish.")
      end

      it "does not add a language instruction for English" do
        client.get_word_suggestions("drink", 5, [], "default", language: "en")
        expect(last_prompt).not_to include("Respond in")
      end
    end

    describe "#get_word_suggestions_from_prompt" do
      it "instructs OpenAI to respond in the language for non-English" do
        client.get_word_suggestions_from_prompt("a prompt", language: "fr")
        expect(last_prompt).to include("Respond in French.")
      end

      it "does not add a language instruction for English" do
        client.get_word_suggestions_from_prompt("a prompt", language: "en")
        expect(last_prompt).not_to include("Respond in")
      end
    end

    describe "#get_words_for_scenario" do
      it "instructs OpenAI to respond in the language for non-English" do
        client.get_words_for_scenario("a scenario", 5, "de")
        expect(last_prompt).to include("Respond in German.")
      end

      it "does not add a language instruction for English" do
        client.get_words_for_scenario("a scenario", 5, "en")
        expect(last_prompt).not_to include("Respond in")
      end
    end

    describe "#get_additional_words" do
      let(:board) { FactoryBot.build(:board, board_type: "static") }

      it "instructs OpenAI to respond in the language for non-English" do
        client.get_additional_words(board, "feelings", 5, [], false, "it")
        expect(last_prompt).to include("Respond in Italian.")
      end

      it "does not add a language instruction for English" do
        client.get_additional_words(board, "feelings", 5, [], false, "en")
        expect(last_prompt).not_to include("Respond in")
      end
    end
  end

  # Regression coverage for the 2026-05-30 production outage (see issue #207):
  # OpenAI clients constructed without a request_timeout could stall a puma
  # thread for the full ruby-openai default of 120s — or longer on TLS half-
  # open conditions. We now pass an explicit cap.
  describe "request_timeout" do
    let(:fake_openai_client) { instance_double(OpenAI::Client) }

    around do |example|
      # Memoization on the class means a prior spec may have cached a client
      # built without the kwarg. Clear both class- and instance-level caches.
      described_class.instance_variable_set(:@openai_client, nil)
      original_token = ENV["OPENAI_ACCESS_TOKEN"]
      ENV["OPENAI_ACCESS_TOKEN"] = "test-token-not-used"
      example.run
    ensure
      ENV["OPENAI_ACCESS_TOKEN"] = original_token
      described_class.instance_variable_set(:@openai_client, nil)
    end

    it "passes request_timeout to OpenAI::Client.new from the class-level accessor" do
      expect(OpenAI::Client).to receive(:new).with(
        hash_including(request_timeout: OpenAiClient::OPENAI_REQUEST_TIMEOUT_SECONDS),
      ).and_return(fake_openai_client)
      expect(described_class.openai_client).to eq(fake_openai_client)
    end

    it "passes request_timeout to OpenAI::Client.new from the instance accessor" do
      expect(OpenAI::Client).to receive(:new).with(
        hash_including(request_timeout: OpenAiClient::OPENAI_REQUEST_TIMEOUT_SECONDS),
      ).and_return(fake_openai_client)
      expect(described_class.new({}).openai_client).to eq(fake_openai_client)
    end

    it "defaults the timeout to 60 seconds" do
      expect(OpenAiClient::OPENAI_REQUEST_TIMEOUT_SECONDS).to eq(60)
    end
  end
end
