# == Schema Information
#
# Table name: child_boards
#
#  id               :bigint           not null, primary key
#  board_id         :bigint           not null
#  child_account_id :bigint           not null
#  status           :string
#  settings         :jsonb
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  published        :boolean          default(FALSE)
#  favorite         :boolean          default(FALSE)
#
require 'rails_helper'

RSpec.describe ChildBoard, type: :model do
  pending "add some examples to (or delete) #{__FILE__}"
end
