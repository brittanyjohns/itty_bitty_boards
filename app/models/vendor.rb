# == Schema Information
#
# Table name: vendors
#
#  id             :bigint           not null, primary key
#  user_id        :bigint
#  business_name  :string
#  business_email :string
#  website        :string
#  location       :string
#  category       :string
#  verified       :boolean          default(FALSE)
#  description    :text
#  configuration  :jsonb
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
class Vendor < ApplicationRecord
  # has_one :profile, as: :profileable, dependent: :destroy
  belongs_to :owner, class_name: "User", foreign_key: "user_id", optional: true
  has_many :users, dependent: :nullify
  belongs_to :user, class_name: "User", foreign_key: "user_id", optional: true
  has_one :child_account, dependent: :destroy
  has_many :boards, dependent: :destroy
  has_many :word_events, dependent: :destroy
  has_many :child_accounts, dependent: :destroy

  # validates :business_name, presence: true
  validates :website, format: { with: URI::regexp(%w[http https]), allow_blank: true }

  CATEGORIES = [
    "Food & Beverage",
    "Retail",
    "Health & Wellness",
    "Technology",
    "Education",
    "Entertainment",
    "Other",
  ].freeze
  validates :category, inclusion: { in: CATEGORIES }, allow_blank: true

  def slug
    profile&.slug || business_name&.parameterize
  end

  def create_profile!
    Rails.logger.info "Creating profile for Vendor: #{business_name} with slug: #{slug}"
    begin
      @account = child_accounts.new(
        username: username,
        name: business_name,
        vendor_id: id,
        user_id: user_id,
      )
      Rails.logger.info "Account before save: #{@account.inspect}"
      @account.save!
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "Error creating child account: #{e.message}"
      account_username = "#{business_name.parameterize}-#{id}"
      @account.username = account_username
      @account.save!
    end
    Rails.logger.info "Account created: #{@account.inspect}" if @account.persisted?
    Rails.logger.error "Failed to create account for Vendor: #{business_name}" unless @account.persisted?
    new_communicator_account = @account

    description = self.description.presence || "Welcome to #{business_name}. Please complete your profile."
    configuration = self.configuration || { "default_language" => "en", "currency" => "USD" }

    Rails.logger.info "Creating profile for new communicator account: #{new_communicator_account.inspect}"
    profile = Profile.find_or_initialize_by(profileable: new_communicator_account)
    Rails.logger.info "Profile found or initialized: #{profile.inspect}"
    profile = Profile.create(profileable: new_communicator_account, username: username, slug: slug,
                             bio: description, intro: "Welcome to #{business_name}", claim_token: SecureRandom.hex(10)) unless profile.persisted?
    if profile.nil?
      profile ||= Profile.new(
        username: @account.username,
        slug: slug,
        bio: description,
        intro: "Welcome to #{business_name}",
        settings: configuration,
        profileable_type: "Vendor",
        profileable_id: id,
        placeholder: verified ? false : true,
        claimed_at: verified ? Time.current : nil,
        claim_token: SecureRandom.hex(10),
      )
    end
    Rails.logger.info "Profile before save: #{profile.inspect}"
    profile.save!
    profile.set_fake_avatar
    if new_communicator_account
      # profile.profileable = new_communicator_account
      profile.placeholder = false
      profile.claimed_at = Time.zone.now
      # profile.username = username
      Rails.logger.info "Setting profileable to new communicator account: #{new_communicator_account.inspect}"
      profile.save!
    end
  end

  def plan_type
    return "free" if user.nil? || user.nil?
    user.plan_type
  end

  def name
    business_name
  end

  def favorite_boards
    user&.favorite_boards || []
  end

  def profiles
    @profiles ||= child_accounts.map(&:profile).compact
  end

  def child_account
    @child_account ||= child_accounts.first
  end

  def profile
    @profile ||= child_account&.profile
  end

  def username
    child_account&.username || business_name.parameterize
  end

  def startup_url
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/vendors/sign-in?username=#{username}"
  end

  def setup_url
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/vendor-accounts/#{id}/qr"
  end

  def public_url
    return nil if slug.blank?
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"

    "#{base_url}/v/#{slug}"
  end

  def self.create_from_email(user_email, business_name, business_email, website = nil)
    user = User.find_by(email: user_email)

    if user
      vendor = create!(
        user: user,
        business_name: business_name,
        business_email: business_email,
        website: website.presence || nil,
        location: "",
        category: CATEGORIES.sample,
        verified: false,
        description: "Welcome to #{business_name}. Please complete your profile.",
        configuration: { "default_language" => "en", "currency" => "USD" },
      )
      vendor.create_profile!
      vendor
    else
      nil
    end
  end

  def voice
    user&.voice || "shimmer"
  end

  def language
    user&.language || "en"
  end

  def account_id
    child_account&.id
  end

  def api_view(viewer = nil)
    {
      id: id,
      business_name: business_name,
      business_email: business_email,
      slug: slug,
      account_id: account_id,
      website: website,
      location: location,
      category: category,
      verified: verified,
      description: description,
      configuration: configuration,
      public_url: public_url,
      profile: profile&.api_view(viewer),
      user_id: user_id,
      can_edit: viewer&.vendor_id == id,
      is_owner: viewer&.id == user_id,
      created_by_email: user&.email,
      users: users.map { |u| { id: u.id, name: u.name, email: u.email } },
      child_accounts: child_accounts.map { |ca| { id: ca.id, username: ca.username, name: ca.name, profile_id: ca.profile&.id, profile_slug: ca.profile&.slug } },
      created_by_name: user&.name,
    }
  end
end
