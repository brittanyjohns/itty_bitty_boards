require "rails_helper"

RSpec.describe OpenaiPrompt, type: :model do
  let(:user) { FactoryBot.create(:user) }
  let(:prompt) do
    OpenaiPrompt.create!(
      user: user,
      prompt_text: "First day of school",
      age_range: "4-6",
      number_of_images: 6,
    )
  end

  def stub_create_chat(content)
    fake_client = instance_double(OpenAiClient)
    allow(OpenAiClient).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:create_chat).and_return({ role: "assistant", content: content })
    fake_client
  end

  describe "#describe_scenario_prompt" do
    it "mentions the prompt_text and age_range" do
      text = prompt.describe_scenario_prompt
      expect(text).to include("First day of school")
      expect(text).to include("aged 4-6")
    end

    it "omits the age clause when age_range is blank" do
      prompt.update!(age_range: nil)
      text = prompt.describe_scenario_prompt
      expect(text).to include("First day of school")
      expect(text).not_to include("aged")
    end

    it "names the required JSON keys" do
      text = prompt.describe_scenario_prompt
      expect(text).to include("\"scenario\"")
      expect(text).to include("\"description\"")
    end
  end

  describe "#set_scenario_description" do
    it "writes description from a valid JSON response" do
      stub_create_chat('{"scenario":"First day of school","description":"meeting the teacher, finding the bathroom, sharing toys"}')

      prompt.set_scenario_description

      expect(prompt.description).to eq("meeting the teacher, finding the bathroom, sharing toys")
    end

    it "tolerates fenced JSON" do
      stub_create_chat("```json\n{\"description\":\"clean text\"}\n```")

      prompt.set_scenario_description

      expect(prompt.description).to eq("clean text")
    end

    it "does not crash on blank response" do
      stub_create_chat(nil)

      expect { prompt.set_scenario_description }.not_to raise_error
      expect(prompt.description).to be_nil
    end

    it "does not crash when 'description' key is missing" do
      stub_create_chat('{"scenario":"X"}')

      expect { prompt.set_scenario_description }.not_to raise_error
      expect(prompt.description).to be_nil
    end
  end

  describe "#send_prompt_to_openai" do
    it "calls OpenAiClient.create_chat with the built messages and stamps sent_at" do
      fake_client = instance_double(OpenAiClient)
      expect(OpenAiClient).to receive(:new) do |opts|
        expect(opts[:messages]).to be_an(Array)
        expect(opts[:messages].length).to eq(2)
        fake_client
      end
      expect(fake_client).to receive(:create_chat).and_return({ role: "assistant", content: '{"words_phrases":["a","b"]}' })

      expect { prompt.send_prompt_to_openai }.to change { prompt.reload.sent_at }
    end

    it "does not stamp sent_at when the client returns nil" do
      fake_client = instance_double(OpenAiClient, create_chat: nil)
      allow(OpenAiClient).to receive(:new).and_return(fake_client)

      expect { prompt.send_prompt_to_openai }.not_to(change { prompt.reload.sent_at })
    end
  end

  describe "#word_list_prompt fallback" do
    it "returns the default prompt when no PromptTemplate exists" do
      allow(PromptTemplate).to receive(:find_by).with(method_name: "word_list_prompt").and_return(nil)

      text = prompt.word_list_prompt

      expect(text).to include("EXACTLY 6")
      expect(text).to include("First day of school")
      expect(text).to include("\"words_phrases\"")
    end

    it "renders the template's placeholders when a PromptTemplate exists" do
      template = PromptTemplate.create!(
        method_name: "word_list_prompt",
        prompt_text: "Give {QUANTITY} words for {NAME} ({AGE_RANGE}) — scenario: {SCENARIO}",
        prompt_type: "word_list",
        response_type: "json",
      )

      text = prompt.word_list_prompt

      expect(text).to eq("Give 6 words for First day of school (4-6) — scenario: First day of school")
      expect(prompt.reload.prompt_template_id).to eq(template.id)
    end
  end
end
