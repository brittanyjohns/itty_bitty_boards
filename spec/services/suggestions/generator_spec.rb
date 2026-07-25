require "rails_helper"

RSpec.describe Suggestions::Generator do
  let(:entry) { Suggestions::Registry.fetch("profile_about_me") }
  let(:context) { { name: "Sam", age_band: "7-10", interests: "trains, drawing" } }
  let(:client) { instance_double(OpenAI::Client) }

  def openai_returning(content)
    allow(described_class).to receive(:openai_client).and_return(client)
    allow(client).to receive(:chat).and_return(
      { "choices" => [{ "message" => { "content" => content } }] },
    )
  end

  # The generator serves fixtures in test so no spec can accidentally bill a
  # real OpenAI call. These examples exercise the live path against a stubbed
  # client, so they opt in explicitly.
  before { allow(described_class).to receive(:use_fixtures?).and_return(false) }

  describe ".use_fixtures?" do
    it "is true in the test environment" do
      allow(described_class).to receive(:use_fixtures?).and_call_original

      expect(described_class.use_fixtures?).to be(true)
    end

    it "is true in staging" do
      allow(described_class).to receive(:use_fixtures?).and_call_original
      allow(AppEnv).to receive(:staging?).and_return(true)

      expect(described_class.use_fixtures?).to be(true)
    end
  end

  describe ".call" do
    it "returns the parsed suggestions" do
      openai_returning({ suggestions: ["Loves trains.", "Waves hello.", "Draws daily."] }.to_json)

      expect(described_class.call(entry, context: context, locale: "en"))
        .to eq(["Loves trains.", "Waves hello.", "Draws daily."])
    end

    it "truncates to the entry's count" do
      openai_returning({ suggestions: %w[one two three four five] }.to_json)

      expect(described_class.call(entry, context: context, locale: "en").length).to eq(3)
    end

    it "caps each suggestion at the entry's max_chars" do
      openai_returning({ suggestions: ["x" * 500] }.to_json)

      result = described_class.call(entry, context: context, locale: "en")
      expect(result.first.length).to eq(entry[:max_chars])
    end

    it "drops blank and non-string entries" do
      openai_returning({ suggestions: ["Loves trains.", "", nil, 42] }.to_json)

      expect(described_class.call(entry, context: context, locale: "en"))
        .to eq(["Loves trains."])
    end

    it "returns an empty array when the model returns malformed JSON" do
      openai_returning("not json at all")

      expect(described_class.call(entry, context: context, locale: "en")).to eq([])
    end

    it "returns an empty array when the API raises" do
      allow(described_class).to receive(:openai_client).and_return(client)
      allow(client).to receive(:chat).and_raise(StandardError, "upstream is down")

      expect(described_class.call(entry, context: context, locale: "en")).to eq([])
    end

    it "serves fixtures without touching OpenAI when fixtures are in force" do
      allow(described_class).to receive(:use_fixtures?).and_return(true)
      expect(described_class).not_to receive(:openai_client)

      result = described_class.call(entry, context: context, locale: "en")
      expect(result.length).to eq(3)
    end

    it "sends the locale and the context to the model" do
      allow(described_class).to receive(:openai_client).and_return(client)
      captured = nil
      allow(client).to receive(:chat) do |parameters:|
        captured = parameters
        { "choices" => [{ "message" => { "content" => { suggestions: ["a"] }.to_json } }] }
      end

      described_class.call(entry, context: context, locale: "es")

      expect(captured[:messages].last[:content]).to include("Sam").and include("trains, drawing")
      expect(captured[:messages].first[:content]).to include("es")
      expect(captured[:response_format]).to eq({ type: "json_object" })
      # request_timeout is a client option, not a chat parameter.
      expect(captured).not_to have_key(:request_timeout)
    end
  end
end
