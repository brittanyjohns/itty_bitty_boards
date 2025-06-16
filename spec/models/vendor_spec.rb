# == Schema Information
#
# Table name: vendors
#
#  id             :bigint           not null, primary key
#  user_id        :bigint
#  business_name  :string
#  business_email :string
#  website        :string
#  location       :string
#  category       :string
#  verified       :boolean          default(FALSE)
#  description    :text
#  configuration  :jsonb
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
require 'rails_helper'

RSpec.describe Vendor, type: :model do
  pending "add some examples to (or delete) #{__FILE__}"
end
