class Vendor < ApplicationRecord
  has_one :profile, as: :profileable, dependent: :destroy
  belongs_to :user, optional: true

  validates :business_name, presence: true
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

  def create_profile!
    return if profile.present?

    slug = business_name.parameterize
    existing_profile = Profile.find_by(slug: slug, profileable_type: "Vendor")
    if existing_profile
      raise "Profile with slug '#{slug}' already exists for Vendor #{business_name}. Please choose a different business name."
    end
    profile = build_profile(
      username: business_name.parameterize,
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

  def api_view(viewer = nil)
    {
      id: id,
      business_name: business_name,
      business_email: business_email,
      website: website,
      location: location,
      category: category,
      verified: verified,
      description: description,
      configuration: configuration,
      profile: profile&.api_view(viewer),
      user_id: user_id,
      can_edit: viewer&.can_edit_vendor?(id),
    }
  end
end
