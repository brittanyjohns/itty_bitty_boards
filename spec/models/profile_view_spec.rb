require "rails_helper"

RSpec.describe ProfileView, type: :model do
  let(:user) { FactoryBot.create(:user) }
  let(:child) { FactoryBot.create(:child_account, user: user, owner: user) }
  let(:profile) { Profile.create!(profileable: child, username: "view-spec", slug: "view-spec") }

  it "belongs to a profile" do
    view = described_class.new
    expect(view).not_to be_valid
    expect(view.errors[:profile]).to be_present
  end

  it "defaults viewed_at on create" do
    view = profile.profile_views.create!
    expect(view.viewed_at).to be_present
  end

  it "defaults geo to an empty hash and notified to false" do
    view = profile.profile_views.create!
    expect(view.geo).to eq({})
    expect(view.notified).to eq(false)
  end

  describe "scopes" do
    it "recent orders newest first" do
      old = profile.profile_views.create!(viewed_at: 2.hours.ago)
      fresh = profile.profile_views.create!(viewed_at: 1.minute.ago)
      expect(described_class.recent.to_a).to eq([fresh, old])
    end

    it "notified returns only notified rows" do
      yes = profile.profile_views.create!(notified: true)
      profile.profile_views.create!(notified: false)
      expect(described_class.notified.to_a).to eq([yes])
    end
  end
end
