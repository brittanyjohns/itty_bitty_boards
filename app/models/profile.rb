# app/models/profile.rb
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
#  sku              :string
#  profile_kind     :string           default("safety"), not null
#
class Profile < ApplicationRecord
  belongs_to :profileable, polymorphic: true, optional: true

  has_many :page_follows, foreign_key: :followed_page_id, dependent: :destroy
  has_many :followers, through: :page_follows, source: :follower_user

  has_one_attached :avatar
  has_one_attached :intro_audio
  has_one_attached :bio_audio

  validates :username, presence: true, uniqueness: true
  validates :slug, presence: true, uniqueness: true
  validates :claim_token, presence: true, uniqueness: true, if: -> { placeholder? }

  before_validation :set_defaults, on: :create
  before_validation :ensure_slug, on: :create

  before_save :set_kind

  has_rich_text :public_about
  has_rich_text :public_intro
  has_rich_text :public_bio

  # --- Kinds (no migration needed; stored in settings for now) ---
  # "safety"         => communicator safety profile
  # "public_page" => pro landing page (SLP/teacher/creator)
  # "placeholder" => unclaimed placeholder record
  PROFILE_KINDS = %w[safety public_page placeholder].freeze

  def safety?
    profile_kind == "safety"
  end

  def public_page?
    profile_kind == "public_page"
  end

  def placeholder_kind?
    profile_kind == "placeholder"
  end

  scope :available_placeholders, -> {
    where(placeholder: true, claimed_at: nil, sku: nil)
  }

  scope :unclaimed_placeholders, -> {
    where(placeholder: true, claimed_at: nil)
  }

  scope :public_pages, -> {
    where(profile_kind: "public_page", allow_discovery: true)
  }

  # --- Ownership helpers ---
  def owner_user_id
    return nil if profileable.nil?

    if profileable_type == "User"
      profileable&.id
    elsif profileable.respond_to?(:user_id)
      profileable&.user_id
    end
  end

  def email
    return nil if profileable.nil?

    if profileable_type == "User"
      profileable&.email
    elsif profileable.respond_to?(:user_email)
      profileable&.user_email
    end
  end

  # --- Public URLs ---
  def public_url
    return nil if slug.blank?

    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    role = profileable&.role.to_s

    if role.include?("vendor")
      "#{base_url}/v/#{slug}"
    elsif profileable_type == "User"
      "#{base_url}/u/#{slug}"
    else
      "#{base_url}/my/#{slug}"
    end
  end

  def claim_url
    return nil if claim_token.blank?
    "#{ENV["FRONT_END_URL"] || "http://localhost:8100"}/c/#{claim_token}"
  end

  def startup_url
    profileable&.startup_url
  end

  # --- Stable background color (was random before) ---
  RANDOM_COLORS = ["#FF5733", "#33FF57", "#3357FF", "#F1C40F", "#E74C3C", "#8E44AD", "#3498DB", "#2ECC71"].freeze

  def bg_color
    seed = (slug.presence || username.presence || id.to_s)
    idx = Zlib.crc32(seed) % RANDOM_COLORS.length
    RANDOM_COLORS[idx]
  end

  # --- Boards ---
  def user_boards
    return [] if profileable.nil?
    return profileable.boards.published.alphabetical if profileable_type == "User"
    []
  end

  def communication_boards
    if profileable&.respond_to?(:favorite_boards) && profileable.favorite_boards.present?
      profileable.favorite_boards
    else
      # Board.public_boards
      []
    end
  end

  def voice
    profileable&.respond_to?(:voice) ? profileable.voice : "polly:kevin"
  end

  def voice_speed
    profileable&.respond_to?(:voice_speed) ? profileable.voice_speed : 1
  end

  def public_boards
      communication_boards
  end

  # --- Attachments / CDN URLs ---
  def avatar_url
    return nil unless avatar.attached?
    key = avatar.key
    return nil if key.blank?
    "#{ENV["CDN_HOST"]}/#{key}"
  end

  def intro_audio_url
    return nil unless intro_audio.attached?
    key = intro_audio.key
    return nil if key.blank?
    "#{ENV["CDN_HOST"]}/#{key}"
  end

  def bio_audio_url
    return nil unless bio_audio.attached?
    key = bio_audio.key
    return nil if key.blank?
    "#{ENV["CDN_HOST"]}/#{key}"
  end

  def set_kind
    if profileable_type == "User" && !public_page?
      self.profile_kind = "public_page"
    end
  end

  # --- Views (IMPORTANT: keep these separated) ---

  # Internal / authenticated view (safe to include settings, but still be careful)
  def api_view(viewer = nil)
    {
      id: id,
      username: username,
      slug: slug,
      bio: bio,
      intro: intro,
      profile_kind: profile_kind,
      public_url: public_url,
      startup_url: startup_url,
      allow_discovery: allow_discovery,

      # Keep full settings ONLY for authenticated/edit contexts
      settings: settings,

      user_boards: user_boards.map(&:api_view),

      avatar: avatar.attached? ? avatar_url : nil,
      intro_audio_url: intro_audio.attached? ? intro_audio_url : nil,
      bio_audio_url: bio_audio.attached? ? bio_audio_url : nil,

      profileable_type: profileable_type,
      profileable_id: profileable_id,
      owner_user_id: owner_user_id,

      can_edit: viewer&.can_edit_profile?(id, "User"),
      viewer: viewer&.id || "anonymous",

      claim_token: claim_token,
      claim_url: claim_url,
      public_about_html: safe_html(public_about&.body&.to_s),
      public_intro_html: safe_html(public_intro&.body&.to_s),
      public_bio_html: safe_html(public_bio&.body&.to_s)
    }
  end

  # Public-facing communicator/safety page view — do NOT leak email / full settings
  def safety_view
    {
      id: id,
      username: username,
      name: profileable.respond_to?(:name) ? profileable.name : username,
      slug: slug,
      profile_kind: profile_kind,

      public_url: public_url,
      intro: intro,
      bio: bio,

      avatar: avatar_url,
      intro_audio_url: intro_audio_url,
      bio_audio_url: bio_audio_url,

      # Only allow ICE-safe settings keys
      settings: public_settings(kind: :safety),


      # Boards shown publicly should be safe/public
      public_boards: public_boards.map(&:api_view),
      general_public_boards: Board.public_boards.map(&:api_view),

      # If you need this for the UI, keep it minimal
      profileable_type: profileable_type,
      profileable_id: profileable_id,

      claim_url: claim_url, # ok to show if you want the CTA
      public_about_html: safe_html(public_about&.body&.to_s),
      public_intro_html: safe_html(public_intro&.body&.to_s),
      public_bio_html: safe_html(public_bio&.body&.to_s)
    }
  end

  # Public Pro landing page view — also do NOT leak email / internal objects
  def public_page_view
    {
      id: id,
      username: username,
      name: profileable.respond_to?(:name) ? profileable.name : username,
      slug: slug,
      profile_kind: profile_kind,
      allow_discovery: allow_discovery,
      public_url: public_url,
      intro: intro,
      bio: bio,

      avatar: avatar_url,
      intro_audio_url: intro_audio_url,
      bio_audio_url: bio_audio_url,

      # Only allow landing-page-safe settings keys
      settings: public_settings(kind: :public_page),

      # If you want this on creator pages, keep it public-only
      public_boards: public_boards.map(&:api_view),
      user_boards: user_boards.map(&:api_view),
      general_public_boards: Board.public_boards.map(&:api_view),
      email: email,
      public_about_html: safe_html(public_about&.body&.to_s),
      public_intro_html: safe_html(public_intro&.body&.to_s),
      public_bio_html: safe_html(public_bio&.body&.to_s)

    }
  end

  def placeholder_view
    {
      id: id,
      username: username,
      slug: slug,
      placeholder: placeholder?,
      profile_kind: profile_kind,
      public_url: public_url,
      claim_token: claim_token,
      claim_url: claim_url,
      sku: sku,
      general_public_boards: Board.public_boards.map(&:api_view),
    }
  end

  def safe_html(html)
    ActionController::Base.helpers.sanitize(
      html,
      tags: %w[p br strong em b i u ul ol li a blockquote h3 h4],
      attributes: %w[href target rel]
    )
  end


  # --- Public settings whitelist ---
  SAFETY_PUBLIC_KEYS = %w[
    allergies
    medical_conditions
    medications
    other_conditions
    other_conditions_notes
    emergency_notes
    emergency_contacts
    ice_contact_1
    ice_contact_2
    ice_contact_3
    ice_contact_4
    ice_contact_5
  ].freeze

  PUBLIC_PAGE_KEYS = %w[
    public_page
    socials
    shop_links
    public_links
    featured_board_ids
    role_badges
    show_email
    headline
  ].freeze

  def public_settings(kind:)
    raw = settings.is_a?(Hash) ? settings : {}

    keys =
      case kind
      when :safety then SAFETY_PUBLIC_KEYS
      when :public_page then PUBLIC_PAGE_KEYS
      else []
      end

    raw.slice(*keys)
  end

  # --- Audio generation ---
  def open_ai_opts
    {}
  end

  def enqueue_audio_job_if_needed
    return if id.blank?

    # Use modern dirty tracking
    intro_changed = saved_change_to_intro? || (intro.present? && !intro_audio.attached?)
    bio_changed   = saved_change_to_bio? || (bio.present? && !bio_audio.attached?)

    return unless intro_changed || bio_changed

    Rails.logger.info "Enqueueing SaveProfileAudioJob for profile #{slug}"
    SaveProfileAudioJob.perform_async(id)
  end

  def update_audio(audio_type)
    return unless intro.present?

    voice = profileable&.respond_to?(:voice) ? (profileable.voice || "openai:alloy") : "openai:alloy"
    language = profileable&.respond_to?(:language) ? (profileable.language || "en") : "en"
    text = ""
    if audio_type == :intro
      text = intro
    elsif audio_type == :bio
      text = bio
    else
      Rails.logger.error "Invalid audio type #{audio_type} for profile #{slug}"
      return
    end

    synth_io = VoiceService.synthesize_speech(text: text, voice_value: voice, language: language)
    return unless synth_io
    unless synth_io
      Rails.logger.error "**** ERROR - create_audio_from_text **** \nNo valid response from VoiceService.synthesize_speech.\n #{synth_io&.inspect}"
      return nil
    end

    unless synth_io.respond_to?(:rewind) && synth_io.respond_to?(:read)
      synth_io = StringIO.new(synth_io)
    end
    Rails.logger.info "Audio synthesized #{audio_type} successfully for profile #{slug}, now attaching..."

    if audio_type == :intro
      save_audio_intro(synth_io, voice, language)
    elsif audio_type == :bio
      save_audio_bio(synth_io, voice, language)
    end
  rescue => e
    Rails.logger.error "#{audio_type.to_s.capitalize} audio failed for profile #{slug}: #{e.message}"
    nil
  end

  def save_audio_intro(audio_io, voice_value, language = "en")
    filename = "#{label_for_filename}_intro.mp3"
    self.intro_audio.attach(io: audio_io, filename: filename, content_type: "audio/mpeg")
    self.reload # Ensure the attached intro_audio is available for URL generation
    self.intro_audio
  end

  def save_audio_bio(audio_io, voice_value, language = "en")
    filename = "#{label_for_filename}_bio.mp3"
    self.bio_audio.attach(io: audio_io, filename: filename, content_type: "audio/mpeg")
    self.reload # Ensure the attached bio_audio is available for URL generation
    self.bio_audio
  end

  def label_for_filename
    file_safe_slug = (slug.presence || username.presence || id.to_s).to_s.parameterize
    "#{file_safe_slug}_#{voice}"
  end

  # --- Placeholders / claiming ---
  def self.create_placeholders(number)
    urls = []
    number.times do
      placeholder_name = "MySpeak #{SecureRandom.hex(4)}"
      slug = placeholder_name.parameterize

      profile = Profile.create!(
        username: placeholder_name,
        slug: slug,
        bio: "This is a placeholder profile waiting to be claimed. Once claimed, you can customize it and make it your own. You can add your own bio, avatar, and other details.",
        intro: "Welcome to MySpeak! Personalize your profile by adding a short introduction about yourself here.",
        placeholder: true,
        claimed_at: nil,
        claim_token: SecureRandom.hex(10),
        settings: { "profile_kind" => "placeholder" },
      )
      profile.set_fake_avatar
      urls << profile.public_url
    end
    urls
  end

  def self.create_for_user(user, username = nil)
    username ||= user.username || SecureRandom.hex(4)
    slug = username.parameterize

    existing_profile = Profile.find_by(username: username) || Profile.find_by(slug: slug)
    return existing_profile if existing_profile&.profileable_type == "User" && existing_profile&.profileable_id == user.id
    return nil if existing_profile.present?

    profile = Profile.create!(
      username: username,
      profileable_type: "User",
      profileable_id: user.id,
      slug: slug,
      bio: "Write a short bio about yourself. This will help others understand who you are and what you do.",
      intro: "Welcome to MySpeak! Personalize your profile by adding a short introduction about yourself.",
      placeholder: false,
      claimed_at: Time.zone.now,
      claim_token: nil,
      settings: { "profile_kind" => "public_page" },
    )
    profile.set_fake_avatar
    profile
  end

  def claim!(username, existing_user)
    user_id = existing_user.id
    existing_communicator = ChildAccount.find_by(username: username, user_id: user_id)

    communicator =
      existing_communicator ||
      ChildAccount.create!(username: username, name: username, user_id: user_id)

    update!(
      profileable: communicator,
      placeholder: false,
      claimed_at: Time.zone.now,
      username: username,
      slug: username.parameterize,
    )

    set_fake_avatar unless avatar.attached?
    self
  end

  def self.generate_with_username(username, existing_user = nil)
    slug = username.parameterize

    existing_profile = Profile.find_by(username: username) || Profile.find_by(slug: slug)
    return nil if existing_profile.present?

    profile = Profile.create!(
      username: username,
      slug: slug,
      bio: "Write a short bio about yourself. This will help others understand who you are and what you do.",
      intro: "Welcome to MySpeak! Personalize your profile by adding a short introduction about yourself.",
      claimed_at: nil,
      claim_token: SecureRandom.hex(10),
      placeholder: true,
      settings: { "profile_kind" => "placeholder" },
    )

    if existing_user
      new_communicator_account = existing_user.communicator_accounts.create!(
        username: username,
        name: username,
      )
      profile.update!(profileable: new_communicator_account, claimed_at: Time.zone.now, placeholder: false)
    end

    profile.set_fake_avatar
    profile
  end

  # --- Defaults ---
  def set_defaults
    self.settings ||= {}

    self.intro = "Welcome to MySpeak! Personalize your profile by adding a short introduction about yourself." if intro.blank?
    self.bio = "Write a short bio about yourself. This will help others understand who you are and what you do." if bio.blank?

    # If you want to infer kind automatically:
    self.settings["profile_kind"] ||= default_profile_kind
  end

  def ensure_slug
    self.slug = username.to_s.parameterize if slug.blank? && username.present?
  end

  def default_profile_kind
    # sensible default without breaking existing behavior
    return "placeholder" if placeholder?
    return "public_page" if profileable_type == "User"
    "safety"
  end

  # --- Avatar generation ---
  def set_fake_avatar
    url =
      if profileable_type == "Vendor"
        "https://api.dicebear.com/9.x/icons/svg?backgroundColor=b6e3f4,c0aede,d1d4f9&seed=#{slug}"
      else
        "https://api.dicebear.com/9.x/adventurer/svg?backgroundColor=b6e3f4,c0aede,d1d4f9&seed=#{slug}"
      end

    avatar.attach(io: URI.open(url), filename: "#{slug}.png")
  end

  private

  def attach_audio_bytes(attachment, bytes, filename)
    tempfile = Tempfile.new([filename, ".mp3"])
    tempfile.binmode
    tempfile.write(bytes)
    tempfile.rewind

    attachment.attach(
      io: tempfile,
      filename: filename,
      content_type: "audio/mpeg",
    )
  ensure
    tempfile.close! if tempfile
  end
end
