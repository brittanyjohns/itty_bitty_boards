# == Schema Information
#
# Table name: profiles
#
#  id               :bigint           not null, primary key
#  profileable_type :string           not null
#  profileable_id   :bigint           not null
#  username         :string
#  slug             :string
#  bio              :text
#  intro            :string
#  settings         :jsonb
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
class Profile < ApplicationRecord
  belongs_to :profileable, polymorphic: true
  has_one_attached :avatar

  validates :username, presence: true, uniqueness: true
  validates :slug, presence: true, uniqueness: true

  before_save :set_slug

  def api_view
    {
      id: id,
      username: username,
      bio: bio,
      slug: slug,
      public_url: public_url,
      intro: intro,
      settings: settings,
      avatar: avatar.attached? ? avatar_url : nil,
    }
  end

  def public_view
    {
      id: id,
      username: username,
      bio: bio,
      name: profileable.name,
      slug: slug,
      public_url: public_url,
      intro: intro,
      public_boards: communication_boards.map(&:api_view),
      avatar: avatar.attached? ? avatar_url : nil,

    }
  end

  def communication_boards
    profileable.favorite_boards
  end

  def public_url
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/my/#{slug}"
  end

  def avatar_url
    image_key = avatar&.key

    cdn_url = "#{ENV["CDN_HOST"]}/#{image_key}" if image_key

    image_key ? cdn_url : nil
  end

  def set_fake_avatar
    url = Faker::Avatar.image(slug: slug, size: "300x300", format: "png")
    avatar.attach(io: URI.open(url), filename: "#{slug}.png")
  end

  private

  def set_slug
    return if username.blank? || slug.present?
    self.slug = username.parameterize
  end
end
