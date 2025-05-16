# == Schema Information
#
# Table name: messages
#
#  id                   :bigint           not null, primary key
#  subject              :string
#  body                 :text
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  sender_id            :integer
#  recipient_id         :integer
#  sent_at              :datetime
#  read_at              :datetime
#  sender_deleted_at    :datetime
#  recipient_deleted_at :datetime
#
require "test_helper"

class MessageTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
