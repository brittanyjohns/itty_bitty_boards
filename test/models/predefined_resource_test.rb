# == Schema Information
#
# Table name: predefined_resources
#
#  id            :bigint           not null, primary key
#  name          :string
#  resource_type :string
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
require "test_helper"

class PredefinedResourceTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
