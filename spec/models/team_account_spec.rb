# == Schema Information
#
# Table name: team_accounts
#
#  id               :bigint           not null, primary key
#  team_id          :bigint           not null
#  child_account_id :bigint           not null
#  active           :boolean          default(TRUE)
#  settings         :jsonb
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
require 'rails_helper'

RSpec.describe TeamAccount, type: :model do
  pending "add some examples to (or delete) #{__FILE__}"
end
