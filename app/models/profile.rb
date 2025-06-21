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
  has_one_attached :bio_audio

  validates :username, presence: true, uniqueness: true
  validates :slug, presence: true, uniqueness: true
  validates :claim_token, presence: true, uniqueness: true, if: -> { placeholder? }

  before_create :set_slug
  before_save :start_audio_job, if: -> { intro_changed? || bio_changed? || (!intro_audio&.attached? && intro.present?) || (!bio_audio&.attached? && bio.present?) }

  def open_ai_opts
    {}
  end

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
      intro_audio_url: intro_audio&.attached? ? intro_audio_url : nil,
      bio_audio_url: bio_audio&.attached? ? bio_audio_url : nil,
      profileable_type: profileable_type,
      profileable_id: profileable_id,
      can_edit: viewer&.can_edit_profile?(id),
    }
  end

  def start_audio_job
    if id.blank?
      Rails.logger.warn "Profile ID is blank, skipping audio job start."
      return
    end

    SaveProfileAudioJob.perform_async(id) if intro.present? && !intro_audio&.attached?
    SaveProfileAudioJob.perform_async(id) if intro_audio&.attached? && intro_changed?
  end

  def label_for_filename
    slug.parameterize
  end

  def update_intro_audio_url
    return unless intro.present?
    voice = profileable&.voice || "alloy"
    language = profileable&.language || "en"
    begin
      response = OpenAiClient.new(open_ai_opts).create_audio_from_text(intro, voice, language)
      if response
        filename = "#{label_for_filename}_intro.aac"
        File.open(filename, "wb") { |f| f.write(response) }
        audio_file = File.open(filename)
        new_audio_file = self.intro_audio.attach(
          io: audio_file,
          filename: filename,
          content_type: "audio/aac",
        )
        file_exists = File.exist?(filename)
        File.delete(filename) if file_exists
        return new_audio_file
      else
        Rails.logger.error "**** ERROR - create_audio_from_text **** \nDid not receive valid response.\n #{response&.inspect}"
      end
    rescue => e
      Rails.logger.error "**** ERROR **** \n#{e.message}\n#{e.inspect}"
    end
    if new_audio_file
      intro_audio.attach(io: new_audio_file, filename: "#{slug}_intro.mp3")
    else
      Rails.logger.error "Failed to create intro audio for profile #{slug}"
    end
  end

  def update_bio_audio_url
    voice = profileable&.voice || "alloy"
    language = profileable&.language || "en"
    begin
      response = OpenAiClient.new(open_ai_opts).create_audio_from_text(bio, voice, language)
      if response
        filename = "#{label_for_filename}_bio.aac"
        File.open(filename, "wb") { |f| f.write(response) }
        audio_file = File.open(filename)
        new_audio_file = self.bio_audio.attach(
          io: audio_file,
          filename: filename,
          content_type: "audio/aac",
        )
        file_exists = File.exist?(filename)
        File.delete(filename) if file_exists
        return new_audio_file
      else
        Rails.logger.error "**** ERROR - create_audio_from_text **** \nDid not receive valid response.\n #{response&.inspect}"
      end
    rescue => e
      Rails.logger.error "**** ERROR **** \n#{e.message}\n#{e.inspect}"
    end
    if new_audio_file
      bio_audio.attach(io: new_audio_file, filename: "#{slug}_bio.mp3")
    else
      Rails.logger.error "Failed to create bio audio for profile #{slug}"
    end
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
      intro_audio_url: intro_audio&.attached? ? intro_audio_url : nil,
      bio_audio_url: bio_audio&.attached? ? bio_audio_url : nil,
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
    role = profileable&.role || "user"
    if role.include?("vendor")
      "#{base_url}/v/#{slug}"
    else
      "#{base_url}/my/#{slug}"
    end
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

  def bio_audio_url
    audio_key = bio_audio&.key
    cdn_url = "#{ENV["CDN_HOST"]}/#{audio_key}" if audio_key
    audio_key ? cdn_url : nil
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

  def self.create_placeholders(number)
    urls = []
    number.times do
      placeholder_name = "MySpeak #{SecureRandom.hex(4)}"
      slug = placeholder_name.parameterize

      profile = Profile.create!(
        username: placeholder_name,
        slug: slug,
        bio: "This is a placeholder profile.",
        intro: "Welcome to MySpeak!",
        placeholder: true,
        claimed_at: nil,
        claim_token: SecureRandom.hex(10),
      )
      urls << profile.public_url
    end
    urls
  end

  def self.generate_with_username(username, existing_user = nil)
    slug = username.parameterize
    Rails.logger.info "Generating profile with user: #{username}, slug: #{slug}, existing_user: #{existing_user.inspect}"

    profile = Profile.create!(
      username: username,
      slug: slug,
      bio: "Write a short bio about yourself. This will help others understand who you are and what you do.",
      intro: "Welcome to MySpeak! Personalize your profile by adding a short introduction about yourself.",
      claimed_at: nil,
      claim_token: SecureRandom.hex(10),
    )
    if existing_user
      new_communicator_account = existing_user.child_accounts.create!(
        username: username,
        name: username,
      )
      profile.profileable = new_communicator_account
      profile.claimed_at = Time.zone.now
      profile.username = username
      profile.save!
    end
    profile.set_fake_avatar
    profile
  end

  private

  def set_slug
    return if username.blank? || slug.present?
    self.slug = username.parameterize
  end
end
