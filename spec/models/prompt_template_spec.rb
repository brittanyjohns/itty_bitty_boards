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
  pending "add some examples to (or delete) #{__FILE__}"
end
