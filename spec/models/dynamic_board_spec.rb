# == Schema Information
#
# Table name: dynamic_boards
#
#  id                    :bigint           not null, primary key
#  name                  :string
#  user_id               :integer
#  parent_id             :integer
#  parent_type           :string
#  description           :text
#  cost                  :integer          default(0)
#  predefined            :boolean          default(FALSE)
#  token_limit           :integer          default(0)
#  voice                 :string           default("echo")
#  status                :string           default("pending")
#  number_of_columns     :integer          default(6)
#  small_screen_columns  :integer          default(3)
#  medium_screen_columns :integer          default(8)
#  large_screen_columns  :integer          default(12)
#  display_image_url     :string
#  layout                :jsonb
#  position              :integer
#  audio_url             :string
#  bg_color              :string
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#
require 'rails_helper'

RSpec.describe DynamicBoard, type: :model do
  pending "add some examples to (or delete) #{__FILE__}"
end
