# == Schema Information
#
# Table name: docs
#
#  id                 :bigint           not null, primary key
#  documentable_type  :string           not null
#  documentable_id    :bigint           not null
#  processed          :text
#  raw                :text
#  current            :boolean          default(FALSE)
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  board_id           :integer
#  user_id            :integer
#  source_type        :string
#  deleted_at         :datetime
#  original_image_url :string
#
require "test_helper"

class DocTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
