# == Schema Information
#
# Table name: board_groups
#
#  id                :bigint           not null, primary key
#  name              :string
#  layout            :jsonb
#  predefined        :boolean          default(FALSE)
#  display_image_url :string
#  position          :integer
#  number_of_columns :integer          default(6)
#  user_id           :integer          not null
#  bg_color          :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
require 'rails_helper'

RSpec.describe BoardGroup, type: :model do
  pending "add some examples to (or delete) #{__FILE__}"
end
