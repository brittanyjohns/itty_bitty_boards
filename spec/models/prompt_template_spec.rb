# == Schema Information
#
# Table name: prompt_templates
#
#  id             :bigint           not null, primary key
#  prompt_type    :string
#  template_name  :string
#  name           :string
#  response_type  :string
#  prompt_text    :text
#  revised_prompt :text
#  preprompt_text :text
#  method_name    :string
#  current        :boolean          default(FALSE)
#  quantity       :integer          default(8)
#  config         :jsonb
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
require 'rails_helper'

RSpec.describe PromptTemplate, type: :model do
  # PromptTemplate rows are admin-editable and drive OpenaiPrompt#word_list_prompt
  # through {QUANTITY}/{SCENARIO}/{AGE_RANGE}/{NAME} placeholders.
  describe "as a prompt source for OpenaiPrompt#word_list_prompt" do
    let(:user) { create(:user) }
    let(:openai_prompt) do
      OpenaiPrompt.create!(user: user, prompt_text: "birthday party",
                           age_range: "4-6", number_of_images: 6)
    end

    it "substitutes every placeholder it defines" do
      create(:prompt_template, method_name: "word_list_prompt",
                               prompt_text: "Give {QUANTITY} words for {SCENARIO} for a {AGE_RANGE} year old ({NAME}).")

      result = openai_prompt.word_list_prompt

      expect(result).to include("6")
      expect(result).to include("4-6")
      expect(result).not_to include("{QUANTITY}")
      expect(result).not_to include("{SCENARIO}")
      expect(result).not_to include("{AGE_RANGE}")
      expect(result).not_to include("{NAME}")
    end

    # This used to be a chain of gsub!, which returns nil when a placeholder is
    # absent — so a row missing {QUANTITY} raised NoMethodError on the next line.
    it "does not raise when the template omits some placeholders" do
      create(:prompt_template, method_name: "word_list_prompt",
                               prompt_text: "Give me words for {SCENARIO}.")

      expect { openai_prompt.word_list_prompt }.not_to raise_error
      expect(openai_prompt.word_list_prompt).to include("birthday party")
    end

    it "falls back to the built-in prompt when no template row exists" do
      expect(openai_prompt.word_list_prompt).to include("words_phrases")
    end

    it "falls back to the built-in prompt when the row has no prompt_text" do
      create(:prompt_template, method_name: "word_list_prompt", prompt_text: nil)

      expect(openai_prompt.word_list_prompt).to include("words_phrases")
    end
  end
end
