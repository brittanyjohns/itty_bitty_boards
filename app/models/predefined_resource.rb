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
  has_many :boards, as: :parent

  def description
    "This is a #{resource_type} resource"
  end

  def self.dynamic_boards(user_id)
    default_resource = self.includes(:boards).where(resource_type: "Board", name: "Default").first_or_create
    default_resource.boards.where(user_id: user_id)
  end

  def self.categories(user_id)
    default_resource = self.includes(:boards).where(resource_type: "Category", name: "Default").first_or_create
    default_resource.boards.where(user_id: user_id)
  end
end
