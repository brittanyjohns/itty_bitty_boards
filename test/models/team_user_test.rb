# == Schema Information
#
# Table name: team_users
#
#  id                     :bigint           not null, primary key
#  user_id                :bigint           not null
#  team_id                :bigint           not null
#  role                   :string
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  invitation_accepted_at :datetime
#  invitation_sent_at     :datetime
#  can_edit               :boolean          default(FALSE)
#
require "test_helper"

class TeamUserTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
