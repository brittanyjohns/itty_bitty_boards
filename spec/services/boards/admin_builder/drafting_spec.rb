require "rails_helper"

RSpec.describe Boards::AdminBuilder::Drafting do
  let(:schema) do
    { name: "test_schema", strict: true, schema: { type: "object", properties: {} } }
  end

  # Captures every OpenAiClient.new(**opts) and answers with `contents` in turn,
  # so a retry can be told apart from the call it retried.
  def stub_client(*contents)
    calls = []
    queue = contents.dup

    allow(OpenAiClient).to receive(:new) do |opts|
      calls << opts
      content = queue.shift
      instance_double(OpenAiClient, create_chat: { role: "assistant", content: content })
        .tap { |double| allow(double).to receive(:instance_variable_set) }
    end

    calls
  end

  describe ".chat" do
    it "returns the content of a successful call" do
      stub_client("{}")

      expect(described_class.chat(prompt: "the park", content: "draft me a board")).to eq("{}")
    end

    it "sends the shared system prompt ahead of the drafter's own" do
      calls = stub_client("{}")
      described_class.chat(prompt: "the park", content: "draft me a board")

      expect(calls.first[:messages]).to eq([
        { role: "system", content: described_class::SYSTEM_PROMPT },
        { role: "user", content: "draft me a board" },
      ])
    end

    it "sends a json schema when given one" do
      calls = stub_client("{}")
      described_class.chat(prompt: "the park", content: "draft", schema: schema)

      expect(calls.first[:response_format]).to eq({ type: "json_schema", json_schema: schema })
    end

    it "sends no response_format when given no schema" do
      calls = stub_client("{}")
      described_class.chat(prompt: "the park", content: "draft")

      expect(calls.first).not_to have_key(:response_format)
    end

    # gpt-5 and the o-series 400 on any temperature but the default, so sending
    # one is a guaranteed wasted round trip that then looks like an empty draft
    # and costs a second call to recover from.
    context "on a reasoning model" do
      before { stub_const("#{described_class}::REASONING_MODEL", true) }

      it "sends no temperature at all" do
        calls = stub_client("{}")
        described_class.chat(prompt: "the park", content: "draft")

        expect(calls.first).not_to have_key(:temperature)
      end

      it "turns the reasoning effort down so the draft lands inside the timeout" do
        calls = stub_client("{}")
        described_class.chat(prompt: "the park", content: "draft")

        expect(calls.first[:reasoning_effort]).to eq(described_class::REASONING_EFFORT)
      end

      # Nothing left to drop, so an empty first call is the end of it.
      it "does not retry a call it never put a temperature on" do
        calls = stub_client(nil, nil)

        expect(described_class.chat(prompt: "the park", content: "draft")).to be_nil
        expect(calls.size).to eq(1)
      end
    end

    it "asks for more than the 60s client default, which a draft does not finish in" do
      calls = stub_client("{}")
      described_class.chat(prompt: "the park", content: "draft")

      expect(calls.first[:request_timeout]).to eq(described_class::REQUEST_TIMEOUT)
      expect(described_class::REQUEST_TIMEOUT).to be > OpenAiClient::OPENAI_REQUEST_TIMEOUT_SECONDS
    end

    # MODEL and TEMPERATURE are both ENV-tunable and `create_chat` swallows an
    # API error into a log line, handing back nil — so a rejected parameter
    # looks exactly like "the AI had nothing to say". Without these retries that
    # would take drafting down until someone read the logs.
    context "when the first call comes back empty" do
      before { stub_const("#{described_class}::REASONING_MODEL", false) }

      it "retries without the temperature" do
        calls = stub_client(nil, "{}")

        expect(described_class.chat(prompt: "the park", content: "draft")).to eq("{}")
        expect(calls.size).to eq(2)
        expect(calls.first).to have_key(:temperature)
        expect(calls.last).not_to have_key(:temperature)
      end

      it "sends no reasoning effort to a model that has none" do
        calls = stub_client("{}")
        described_class.chat(prompt: "the park", content: "draft")

        expect(calls.first).not_to have_key(:reasoning_effort)
      end

      it "then retries without the schema, and keeps the schema off both attempts" do
        calls = stub_client(nil, nil, "{}")

        expect(described_class.chat(prompt: "the park", content: "draft", schema: schema)).to eq("{}")
        expect(calls.size).to eq(3)
        expect(calls.first[:response_format]).to be_present
        expect(calls.last).not_to have_key(:response_format)
      end

      it "gives up and returns nil when nothing works" do
        calls = stub_client(nil, nil, nil, nil)

        expect(described_class.chat(prompt: "the park", content: "draft", schema: schema)).to be_nil
        expect(calls.size).to eq(4)
      end

      it "does not retry a schema-less call a second time" do
        calls = stub_client(nil, nil)

        expect(described_class.chat(prompt: "the park", content: "draft")).to be_nil
        expect(calls.size).to eq(2)
      end
    end
  end

  describe ".tile_schema" do
    # Structured Outputs strict mode requires every property in `required` and
    # forbids extras, so an optional field is modelled as nullable rather than
    # left out.
    it "pins the part of speech to the Fitzgerald key" do
      expect(described_class.tile_schema.dig(:properties, :part_of_speech, :enum))
        .to eq(ColorHelper::PARTS_OF_SPEECH)
    end

    it "requires every property it defines and forbids the rest" do
      schema = described_class.tile_schema

      expect(schema[:additionalProperties]).to be(false)
      expect(schema[:required]).to match_array(%w[label part_of_speech proper_noun links_to])
    end

    it "makes an optional link nullable rather than absent" do
      expect(described_class.tile_schema.dig(:properties, :links_to, :type)).to eq(%w[string null])
    end

    # WordListDrafter replaces a whole word list and knows nothing about the
    # pages in the set, so a link it invented would name a page that doesn't
    # exist.
    it "omits links entirely when asked to" do
      schema = described_class.tile_schema(links: false)

      expect(schema[:properties]).not_to have_key(:links_to)
      expect(schema[:required]).not_to include("links_to")
    end
  end
end
