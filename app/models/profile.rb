# == Schema Information
#
# Table name: profiles
#
#  id               :bigint           not null, primary key
#  profileable_type :string
#  profileable_id   :bigint
#  username         :string
#  slug             :string
#  bio              :text
#  intro            :string
#  settings         :jsonb
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  placeholder      :boolean          default(FALSE)
#  claim_token      :string
#  claimed_at       :datetime
#
class Profile < ApplicationRecord
  belongs_to :profileable, polymorphic: true, optional: true
  has_one_attached :avatar
  has_one_attached :intro_audio

  validates :username, presence: true, uniqueness: true
  validates :slug, presence: true, uniqueness: true
  validates :claim_token, presence: true, uniqueness: true, if: -> { placeholder? }

  before_create :set_slug

  def api_view(viewer = nil)
    {
      id: id,
      username: username,
      bio: bio,
      slug: slug,
      public_url: public_url,
      startup_url: startup_url,
      intro: intro,
      settings: settings,
      avatar: avatar.attached? ? avatar_url : nil,
      intro_audio: intro_audio.attached? ? intro_audio_url : nil,
      profileable_type: profileable_type,
      profileable_id: profileable_id,
      can_edit: viewer&.can_edit_profile?(id),
    }
  end

  RANDOM_COLORS = ["#FF5733", "#33FF57", "#3357FF", "#F1C40F", "#E74C3C", "#8E44AD", "#3498DB", "#2ECC71"].freeze

  def bg_color
    random_color = RANDOM_COLORS.sample
    random_color
  end

  def public_boards
    return [] if profileable.nil? || communication_boards.nil?
    communication_boards.any? ? communication_boards : Board.public_boards
  end

  def public_view
    {
      id: id,
      username: username,
      bio: bio,
      name: profileable&.name,
      slug: slug,
      public_url: public_url,
      startup_url: startup_url,
      intro: intro,
      public_boards: public_boards.map(&:api_view),
      profileable_type: profileable_type,
      profileable_id: profileable_id,
      user_id: profileable_type == "User" ? profileable&.id : profileable&.user_id,
      communicator_account_id: profileable_type == "User" ? nil : profileable&.id,
      avatar: avatar.attached? ? avatar_url : nil,
      settings: settings,

    }
  end

  def placeholder_view
    {
      id: id,
      username: username,
      bio: bio,
      slug: slug,
      placeholder: true,
      public_url: public_url,
    }
  end

  def communication_boards
    profileable&.favorite_boards
  end

  def public_url
    return nil if slug.blank?
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"

    "#{base_url}/my/#{slug}"

    # if placeholder
    #   "#{base_url}/claim/#{claim_token}"
    # else
    #   "#{base_url}/my/#{slug}"
    # end
  end

  def startup_url
    profileable&.startup_url
  end

  def avatar_url
    image_key = avatar&.key

    cdn_url = "#{ENV["CDN_HOST"]}/#{image_key}" if image_key

    image_key ? cdn_url : nil
  end

  def set_fake_avatar
    url = FFaker::Avatar.image(slug: slug, size: "300x300", format: "png")
    avatar.attach(io: URI.open(url), filename: "#{slug}.png")
  end

  def intro_audio_url
    audio_key = intro_audio&.key
    cdn_url = "#{ENV["CDN_HOST"]}/#{audio_key}" if audio_key
    audio_key ? cdn_url : nil
  end

  def set_fake_intro_audio
    url = FFaker::Audio.audio(slug: slug, format: "mp3")
    intro_audio.attach(io: URI.open(url), filename: "#{slug}.mp3")
  end

  def claim!(communicator)
    update!(
      profileable: communicator,
      claim_token: nil,
      placeholder: false,
      claimed_at: Time.zone.now,
      username: communicator.username.presence || self.username,
    )
  end

  private

  def set_slug
    return if username.blank? || slug.present?
    self.slug = username.parameterize
  end
end
