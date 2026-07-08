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
#  allow_discovery  :boolean          default(FALSE), not null
#  slug_changed_at  :datetime
#
require "rails_helper"

RSpec.describe Profile, type: :model do
  let(:user) { FactoryBot.create(:user) }
  let(:child) { FactoryBot.create(:child_account, user: user, owner: user) }

  def build_profile(slug:, **overrides)
    Profile.new(
      profileable: child,
      username: overrides.fetch(:username, slug),
      slug: slug,
      bio: "bio",
      intro: "intro",
    )
  end

  describe "slug format validation (on change)" do
    it "accepts a kebab-case 3-40 char slug" do
      profile = build_profile(slug: "river-stone-42")
      expect(profile).to be_valid
    end

    it "rejects a slug with uppercase letters" do
      profile = build_profile(slug: "River-Stone")
      expect(profile).not_to be_valid
      expect(profile.errors[:slug].join).to match(/lowercase/)
    end

    it "rejects a slug with underscores" do
      profile = build_profile(slug: "river_stone")
      expect(profile).not_to be_valid
    end

    it "rejects a slug shorter than 3 chars" do
      profile = build_profile(slug: "ab")
      expect(profile).not_to be_valid
    end

    it "rejects a slug longer than 40 chars" do
      profile = build_profile(slug: "a" + "b" * 40)
      expect(profile).not_to be_valid
    end

    it "rejects leading or trailing hyphen" do
      expect(build_profile(slug: "-river")).not_to be_valid
      expect(build_profile(slug: "river-")).not_to be_valid
    end

    it "leaves legacy rows alone when unrelated fields are updated" do
      # Bypass validations to seed a legacy slug, then update an unrelated field.
      profile = build_profile(slug: "ok-slug").tap { |p| p.save!(validate: false) }
      profile.update_columns(slug: "Legacy_Slug")
      profile.reload
      profile.bio = "edited"
      expect(profile).to be_valid
    end
  end

  describe "reserved slug rejection (on change)" do
    %w[admin api myspeak speakanyway m u v p c onboarding].each do |reserved|
      it "rejects #{reserved.inspect}" do
        profile = build_profile(slug: reserved)
        expect(profile).not_to be_valid
        expect(profile.errors[:slug].join).to match(/reserved/)
      end
    end

    it "rejects an all-numeric slug" do
      profile = build_profile(slug: "1234567")
      expect(profile).not_to be_valid
      expect(profile.errors[:slug].join).to match(/all numbers/)
    end
  end

  describe "#slug_editable?" do
    let(:profile) do
      build_profile(slug: "river-stone").tap(&:save!)
    end

    it "is true when slug_changed_at is nil" do
      profile.update_columns(slug_changed_at: nil)
      expect(profile.slug_editable?).to be(true)
    end

    it "is false within 7 days of the last change" do
      profile.update_columns(slug_changed_at: 1.day.ago)
      expect(profile.slug_editable?).to be(false)
    end

    it "is true once 7 days have passed" do
      profile.update_columns(slug_changed_at: 8.days.ago)
      expect(profile.slug_editable?).to be(true)
    end
  end

  describe "#slug_editable_at" do
    let(:profile) do
      build_profile(slug: "river-stone").tap(&:save!)
    end

    it "is nil when slug_changed_at is nil" do
      profile.update_columns(slug_changed_at: nil)
      expect(profile.slug_editable_at).to be_nil
    end

    it "is 7 days after the last change" do
      changed_at = 2.days.ago.beginning_of_minute
      profile.update_columns(slug_changed_at: changed_at)
      expect(profile.slug_editable_at).to be_within(1.second).of(changed_at + 7.days)
    end
  end

  describe "touch_slug_changed_at callback" do
    it "does NOT set slug_changed_at on initial create" do
      profile = build_profile(slug: "river-stone")
      expect { profile.save! }.not_to change { profile.slug_changed_at }
      expect(profile.slug_changed_at).to be_nil
    end

    it "sets slug_changed_at when slug is changed on an existing record" do
      profile = build_profile(slug: "river-stone").tap(&:save!)
      profile.slug = "new-slug"
      expect { profile.save! }.to change { profile.slug_changed_at }.from(nil)
    end

    it "does NOT update slug_changed_at when an unrelated field changes" do
      profile = build_profile(slug: "river-stone").tap(&:save!)
      profile.bio = "edited"
      expect { profile.save! }.not_to change { profile.slug_changed_at }
    end
  end

  describe ".slug_available?" do
    it "is true for a fresh slug" do
      expect(Profile.slug_available?("totally-new")).to be(true)
    end

    it "is false when another Profile has the slug" do
      build_profile(slug: "river-stone").save!
      expect(Profile.slug_available?("river-stone")).to be(false)
    end

    it "is false when another Profile uses the value as its username" do
      Profile.new(
        profileable: child,
        username: "claimed-name",
        slug: "different-slug",
      ).save!(validate: false)
      expect(Profile.slug_available?("claimed-name")).to be(false)
    end

    it "is false when a ChildAccount uses the value as its login username" do
      FactoryBot.create(:child_account, user: user, owner: user, username: "logged-in-user")
      expect(Profile.slug_available?("logged-in-user")).to be(false)
    end

    it "excludes the profile's own id when except_id is supplied" do
      profile = build_profile(slug: "river-stone").tap(&:save!)
      expect(Profile.slug_available?("river-stone", except_id: profile.id)).to be(true)
    end
  end

  describe ".slug_unavailable_reason" do
    it "returns :format for blank / bad-shape input" do
      expect(Profile.slug_unavailable_reason("")).to eq(:format)
      expect(Profile.slug_unavailable_reason("Bad_Slug")).to eq(:format)
    end

    it "returns :reserved for the reserved list" do
      expect(Profile.slug_unavailable_reason("admin")).to eq(:reserved)
    end

    it "returns :reserved for all-numeric" do
      expect(Profile.slug_unavailable_reason("1234")).to eq(:reserved)
    end

    it "returns :taken when the slug exists elsewhere" do
      build_profile(slug: "river-stone").save!
      expect(Profile.slug_unavailable_reason("river-stone")).to eq(:taken)
    end

    it "returns nil for a fresh, well-formed slug" do
      expect(Profile.slug_unavailable_reason("river-stone")).to be_nil
    end
  end

  # The public views back unauthenticated profile pages. They must not leak
  # the communicator's full api_view (parent email, passcode, claim tokens)
  # nor a raw email field.
  describe "#safety_view" do
    let(:profile) { build_profile(slug: "safe-page").tap(&:save!) }

    it "omits communicator_account and email" do
      view = profile.safety_view
      expect(view).not_to have_key(:communicator_account)
      expect(view).not_to have_key(:email)
    end

    it "exposes a sanitized theme in the page-safe settings" do
      profile.update!(settings: { "theme" => { "preset" => "ocean", "accent" => "#0EA5E9" } })
      expect(profile.safety_view[:settings]["theme"]).to eq("preset" => "ocean", "accent" => "#0EA5E9")
    end

    it "never exposes sensitive safety keys in the page-safe settings" do
      profile.update!(settings: { "allergies" => "peanuts", "ice_contact_1" => "Mom" })
      expect(profile.safety_view[:settings]).not_to have_key("allergies")
      expect(profile.safety_view[:settings]).not_to have_key("ice_contact_1")
    end
  end

  describe "sanitize_theme_settings callback" do
    let(:profile) { build_profile(slug: "theme-page").tap(&:save!) }

    it "keeps valid hex and slug values" do
      profile.update!(settings: {
        "theme" => {
          "preset" => "sunset",
          "bg_style" => "gradient",
          "accent" => "#0EA5E9",
          "bg_color" => "#F0F9FF",
          "border_color" => "#BAE6FD",
          "text_color" => "#0C4A6E",
        },
      })
      expect(profile.reload.settings["theme"]).to eq(
        "accent" => "#0EA5E9",
        "bg_color" => "#F0F9FF",
        "border_color" => "#BAE6FD",
        "text_color" => "#0C4A6E",
        "preset" => "sunset",
        "bg_style" => "gradient",
      )
    end

    it "drops invalid hex values (named color, short hex)" do
      profile.update!(settings: { "theme" => { "accent" => "red", "bg_color" => "#fff" } })
      expect(profile.reload.settings).not_to have_key("theme")
    end

    it "drops a CSS-injection attempt in a hex field" do
      profile.update!(settings: { "theme" => { "accent" => "#fff; background:url(javascript:alert(1))" } })
      expect(profile.reload.settings).not_to have_key("theme")
    end

    it "drops slug values that aren't simple slugs" do
      profile.update!(settings: { "theme" => { "preset" => "Ocean Blue!", "accent" => "#0EA5E9" } })
      theme = profile.reload.settings["theme"]
      expect(theme).to eq("accent" => "#0EA5E9")
      expect(theme).not_to have_key("preset")
    end

    it "strips unknown keys (whitelist, not blocklist)" do
      profile.update!(settings: { "theme" => { "accent" => "#0EA5E9", "evil" => "boom", "font" => "Comic Sans" } })
      expect(profile.reload.settings["theme"]).to eq("accent" => "#0EA5E9")
    end

    it "deletes the key when theme is not a hash" do
      profile.update!(settings: { "theme" => "hacker" })
      expect(profile.reload.settings).not_to have_key("theme")
    end

    it "deletes the key when every theme value is invalid" do
      profile.update!(settings: { "theme" => { "accent" => "nope", "preset" => "" } })
      expect(profile.reload.settings).not_to have_key("theme")
    end

    it "leaves non-theme settings untouched" do
      profile.update!(settings: { "pronouns" => "she/her", "theme" => { "accent" => "#0EA5E9" } })
      settings = profile.reload.settings
      expect(settings["pronouns"]).to eq("she/her")
      expect(settings["theme"]).to eq("accent" => "#0EA5E9")
    end
  end

  describe "#public_page_view" do
    let(:profile) do
      build_profile(slug: "pro-page").tap do |p|
        p.profile_kind = "public_page"
        p.save!
      end
    end

    it "omits the raw email field" do
      expect(profile.public_page_view).not_to have_key(:email)
    end

    it "exposes a ChildAccount communicator_account via the sanitized public_api_view" do
      view = profile.public_page_view
      expect(view[:communicator_account]).to eq(child.public_api_view)
      expect(view[:communicator_account].keys).to contain_exactly(:id, :name, :avatar_url, :voice, :boards)
    end

    it "does not leak the communicator's parent email or passcode" do
      account = profile.public_page_view[:communicator_account]
      expect(account).not_to have_key(:parent_email)
      expect(account).not_to have_key(:passcode)
    end
  end

  describe ".generate_random_slug" do
    it "returns an 's-' prefix plus 6 unambiguous alphanumeric chars" do
      slug = Profile.generate_random_slug
      expect(slug).to match(/\As-[a-z0-9]{6}\z/)
    end

    it "never includes ambiguous characters (0, o, 1, l, i)" do
      200.times do
        body = Profile.generate_random_slug.delete_prefix("s-")
        expect(body).not_to match(/[0o1li]/)
      end
    end

    it "retries until it finds a slug not already used as slug or legacy_slug" do
      # Force the first candidate to collide, the second to be free.
      allow(Profile).to receive(:exists?).and_return(true, true, false, false)
      expect(Profile.generate_random_slug).to match(/\As-[a-z0-9]{6}\z/)
    end
  end

  describe "#ensure_slug (random safety slugs)" do
    it "assigns a random slug + slug_type 'random' to a safety profile with no slug" do
      profile = Profile.new(profileable: child, username: "emma-jones")
      profile.save!
      expect(profile.slug).to match(/\As-[a-z0-9]{6}\z/)
      expect(profile.slug_type).to eq("random")
    end

    it "does not overwrite an explicitly provided slug" do
      profile = build_profile(slug: "emma-jones").tap(&:save!)
      expect(profile.slug).to eq("emma-jones")
      expect(profile.slug_type).to eq("legacy")
    end

    it "derives a readable slug from the username for a non-safety profile" do
      profile = Profile.new(
        profileable: user,
        profile_kind: "public_page",
        username: "Pat Smith",
      )
      profile.save!
      expect(profile.slug).to eq("pat-smith")
      expect(profile.slug_type).to eq("legacy")
    end
  end

  describe "#slug_editable? with a random slug" do
    it "is false even when slug_changed_at is blank" do
      profile = Profile.new(profileable: child, username: "emma").tap(&:save!)
      expect(profile.slug_type).to eq("random")
      expect(profile.slug_changed_at).to be_nil
      expect(profile.slug_editable?).to be(false)
    end
  end

  describe ".slug_available? with legacy_slug" do
    it "is false when the value matches an existing legacy_slug" do
      profile = Profile.new(profileable: child, username: "emma").tap(&:save!)
      profile.update_columns(legacy_slug: "emma-jones")
      expect(Profile.slug_available?("emma-jones")).to be(false)
    end
  end
end
