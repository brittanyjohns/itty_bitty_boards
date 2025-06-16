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
  has_one :profile, as: :profileable, dependent: :destroy
  belongs_to :user, optional: true

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
    profile&.slug || business_name.parameterize
  end

  def create_profile!
    return if profile.present?

    existing_profile = Profile.find_by(slug: slug, profileable_type: "Vendor")
    if existing_profile
      raise "Profile with slug '#{slug}' already exists for Vendor #{business_name}. Please choose a different business name."
    end
    profile = build_profile(
      username: slug,
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
    profile.save!
    profile.set_fake_avatar
    if user
      new_communicator_account = user.child_accounts.create!(
        username: username,
        name: business_name,
      )
      profile.profileable = new_communicator_account
      profile.placeholder = false
      profile.claimed_at = Time.zone.now
      profile.username = username
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

  def username
    profile&.username || business_name.parameterize
  end

  def startup_url
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/vendors/sign-in?username=#{username}"
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
    profile&.profileable_type == "ChildAccount" ? profileable_id : user&.id
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
      can_edit: viewer&.can_edit_vendor?(id),
      is_owner: viewer&.id == user_id,
      created_by_email: user&.email,
      created_by_name: user&.name,
    }
  end
end
