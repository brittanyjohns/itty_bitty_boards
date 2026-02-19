# app/models/page_follow.rb
class PageFollow < ApplicationRecord
  belongs_to :follower_user, class_name: "User"
  belongs_to :page, class_name: "Page", foreign_key: :followed_page_id

  validates :followed_page_id, uniqueness: { scope: :follower_user_id }
  validate :cannot_follow_own_page

  private

  def cannot_follow_own_page
    return unless page&.profileable_type == "User"
    return unless page&.profileable_id == follower_user_id
    errors.add(:followed_page_id, "can't follow your own page")
  end
end
