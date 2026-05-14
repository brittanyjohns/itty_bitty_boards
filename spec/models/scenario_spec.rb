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
require 'rails_helper'

RSpec.describe Scenario, type: :model do
  describe "#get_words_for_scenario" do
    let(:scenario) { FactoryBot.build(:scenario) }
    let(:openai) { instance_double(OpenAiClient) }

    before { allow(OpenAiClient).to receive(:new).and_return(openai) }

    it "passes the language through to OpenAiClient" do
      expect(openai).to receive(:get_words_for_scenario)
        .with("a description", 12, "es")
        .and_return({ content: '{"words":[]}' })
      scenario.get_words_for_scenario("a description", 12, "es")
    end

    it "defaults to English when no language is given" do
      expect(openai).to receive(:get_words_for_scenario)
        .with("a description", 12, "en")
        .and_return({ content: '{"words":[]}' })
      scenario.get_words_for_scenario("a description", 12)
    end

    it "returns early without calling OpenAI when the description is blank" do
      expect(OpenAiClient).not_to receive(:new)
      expect(scenario.get_words_for_scenario("", 12, "es")).to be_nil
    end
  end
end
