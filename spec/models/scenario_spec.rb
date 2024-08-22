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
  pending "add some examples to (or delete) #{__FILE__}"
end
