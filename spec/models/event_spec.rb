# == Schema Information
#
# Table name: events
#
#  id         :bigint           not null, primary key
#  name       :string
#  slug       :string
#  date       :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  promo_code :string
#
require 'rails_helper'

RSpec.describe Event, type: :model do
  pending "add some examples to (or delete) #{__FILE__}"
end
