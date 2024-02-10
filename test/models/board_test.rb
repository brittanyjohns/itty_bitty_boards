# == Schema Information
#
# Table name: boards
#
#  id                :bigint           not null, primary key
#  user_id           :bigint           not null
#  name              :string
#  parent_type       :string           not null
#  parent_id         :bigint           not null
#  description       :text
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  cost              :integer          default(0)
#  predefined        :boolean          default(FALSE)
#  token_limit       :integer          default(0)
#  number_of_columns :integer          default(4)
#
require "test_helper"

class BoardTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
