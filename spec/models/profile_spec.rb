# == Schema Information
#
# Table name: profiles
#
#  id               :bigint           not null, primary key
#  profileable_type :string           not null
#  profileable_id   :bigint           not null
#  username         :string
#  slug             :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
require 'rails_helper'

RSpec.describe Profile, type: :model do
  pending "add some examples to (or delete) #{__FILE__}"
end
