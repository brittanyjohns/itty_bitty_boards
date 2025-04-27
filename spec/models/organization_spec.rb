# == Schema Information
#
# Table name: organizations
#
#  id                 :bigint           not null, primary key
#  name               :string
#  slug               :string
#  admin_user_id      :bigint           not null
#  settings           :jsonb
#  stripe_customer_id :string
#  plan_type          :string
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
require 'rails_helper'

RSpec.describe Organization, type: :model do
  pending "add some examples to (or delete) #{__FILE__}"
end
