# == Schema Information
#
# Table name: contest_entries
#
#  id         :bigint           not null, primary key
#  name       :string
#  email      :string
#  data       :jsonb
#  event_id   :bigint           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  winner     :boolean          default(FALSE)
#
require 'rails_helper'

RSpec.describe ContestEntry, type: :model do
  pending "add some examples to (or delete) #{__FILE__}"
end
