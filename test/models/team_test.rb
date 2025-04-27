# == Schema Information
#
# Table name: teams
#
#  id              :bigint           not null, primary key
#  name            :string
#  created_by_id   :integer          not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organization_id :bigint
#
require "test_helper"

class TeamTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
