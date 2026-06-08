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
end
