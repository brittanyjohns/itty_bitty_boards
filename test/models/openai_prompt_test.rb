# == Schema Information
#
# Table name: openai_prompts
#
#  id             :bigint           not null, primary key
#  user_id        :bigint           not null
#  prompt_text    :text
#  revised_prompt :text
#  send_now       :boolean          default(FALSE)
#  deleted_at     :datetime
#  sent_at        :datetime
#  private        :boolean          default(FALSE)
#  age_range      :string
#  response_type  :string
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
require "test_helper"

class OpenaiPromptTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
