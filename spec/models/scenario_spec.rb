# == Schema Information
#
# Table name: scenarios
#
#  id                  :bigint           not null, primary key
#  questions           :json
#  answers             :json
#  name                :string
#  initial_description :text
#  age_range           :string
#  user_id             :bigint           not null
#  status              :string           default("pending")
#  word_list           :string           default([]), is an Array
#  token_limit         :integer          default(10)
#  board_id            :integer
#  send_now            :boolean          default(FALSE)
#  number_of_images    :integer          default(0)
#  tokens_used         :integer          default(0)
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
require "rails_helper"

RSpec.describe Scenario, type: :model do
  let(:user) { FactoryBot.create(:user) }
  let(:scenario) { FactoryBot.create(:scenario, user: user, name: "First day of school") }

  def stub_openai_words(content)
    fake_client = instance_double(OpenAiClient)
    allow(OpenAiClient).to receive(:new).and_return(fake_client)
    allow(fake_client).to receive(:get_words_for_scenario).and_return({ role: "assistant", content: content })
    fake_client
  end

  describe "#get_words_for_scenario" do
    it "returns a deduped, lowercased word list from a valid response" do
      stub_openai_words('{"words":["Apple","banana","APPLE","Cherry"]}')

      result = scenario.get_words_for_scenario("a scenario", 4)

      expect(result).to eq(%w[apple banana cherry])
    end

    it "tolerates fenced JSON output" do
      stub_openai_words("```json\n{\"words\":[\"a\",\"b\"]}\n```")

      expect(scenario.get_words_for_scenario("x", 2)).to eq(%w[a b])
    end

    it "returns nil when description is blank" do
      expect(OpenAiClient).not_to receive(:new)
      expect(scenario.get_words_for_scenario("", 5)).to be_nil
    end

    it "returns nil when number_of_words is blank" do
      expect(OpenAiClient).not_to receive(:new)
      expect(scenario.get_words_for_scenario("x", nil)).to be_nil
    end

    it "returns nil when the AI returns blank content" do
      stub_openai_words(nil)

      expect(scenario.get_words_for_scenario("x", 5)).to be_nil
    end

    it "returns nil when the AI returns the NO ADDITIONAL WORDS sentinel" do
      stub_openai_words('NO ADDITIONAL WORDS — {"words":["a"]}')

      expect(scenario.get_words_for_scenario("x", 5)).to be_nil
    end

    it "passes description and number_of_words to OpenAiClient" do
      fake_client = instance_double(OpenAiClient)
      allow(OpenAiClient).to receive(:new).and_return(fake_client)
      expect(fake_client).to receive(:get_words_for_scenario).with("road trip", 12).and_return({ content: '{"words":[]}' })

      scenario.get_words_for_scenario("road trip", 12)
    end
  end
end
