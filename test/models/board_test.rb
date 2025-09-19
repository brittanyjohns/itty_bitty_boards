# == Schema Information
#
# Table name: boards
#
#  id                    :bigint           not null, primary key
#  user_id               :bigint           not null
#  name                  :string
#  parent_type           :string           not null
#  parent_id             :bigint           not null
#  description           :text
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  cost                  :integer          default(0)
#  predefined            :boolean          default(FALSE)
#  token_limit           :integer          default(0)
#  voice                 :string
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
#  margin_settings       :jsonb
#  settings              :jsonb
#  category              :string
#  data                  :jsonb
#  group_layout          :jsonb
#  image_parent_id       :integer
#  board_type            :string
#  obf_id                :string
#  language              :string           default("en")
#  board_images_count    :integer          default(0), not null
#  published             :boolean          default(FALSE)
#  favorite              :boolean          default(FALSE)
#  vendor_id             :bigint
#  slug                  :string           default("")
#  in_use                :boolean          default(FALSE), not null
#  is_template           :boolean          default(FALSE), not null
#
require "test_helper"

class BoardTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
