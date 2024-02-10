# == Schema Information
#
# Table name: predefined_resources
#
#  id            :bigint           not null, primary key
#  name          :string
#  resource_type :string
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
class PredefinedResource < ApplicationRecord
end
