require "rails_helper"

RSpec.describe RecordProfileViewJob, type: :sidekiq do
  let(:job) { described_class.new }
  let(:owner) { FactoryBot.create(:user, email: "parent@example.com") }
  let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Sky") }
  let(:profile) { Profile.create!(profileable: child, username: "sky-job", slug: "sky-job") }

  before do
    # Coarse geo is mocked so the suite never makes a network call.
    allow(IpGeolocation).to receive(:coarse).and_return(
      city: "Austin", region: "Texas", country: "US", label: "Austin, Texas, US"
    )
    # Clear the per-profile throttle key so each example starts fresh.
    Sidekiq.redis { |c| c.call("DEL", "safety_view_notify:#{profile.id}") }
  end

  def deliveries = ActionMailer::Base.deliveries.size

  describe "#perform" do
    it "logs a ProfileView and emails the parent" do
      expect {
        job.perform(profile.id, "8.8.8.8", "Mozilla/5.0")
      }.to change { ProfileView.count }.by(1).and change { deliveries }.by(1)

      view = ProfileView.last
      expect(view.profile).to eq(profile)
      expect(view.ip_address).to eq("8.8.8.8")
      expect(view.user_agent).to eq("Mozilla/5.0")
      expect(view.approx_location).to eq("Austin, Texas, US")
      expect(view.geo).to include("city" => "Austin", "country" => "US")
      expect(view.notified).to eq(true)
    end

    it "still logs and emails when geolocation yields nothing (no location in the email)" do
      allow(IpGeolocation).to receive(:coarse).and_return(nil)

      expect {
        job.perform(profile.id, "8.8.8.8", "UA")
      }.to change { ProfileView.count }.by(1).and change { deliveries }.by(1)

      view = ProfileView.last
      expect(view.approx_location).to be_nil
      expect(view.geo).to eq({})
    end

    it "does nothing for a non-safety profile" do
      pro = Profile.new(profileable: child, username: "sky-pro", slug: "sky-pro")
      pro.profile_kind = "public_page"
      pro.save!

      expect {
        job.perform(pro.id, "8.8.8.8", "UA")
      }.to change { ProfileView.count }.by(0).and change { deliveries }.by(0)
    end

    it "no-ops when the profile is missing" do
      expect {
        job.perform(-1, "8.8.8.8", "UA")
      }.to change { ProfileView.count }.by(0).and change { deliveries }.by(0)
    end

    it "logs the view but sends no email when the parent opted out of view alerts" do
      profile.update!(settings: { "view_alerts_enabled" => false })

      expect {
        job.perform(profile.id, "8.8.8.8", "UA")
      }.to change { ProfileView.count }.by(1).and change { deliveries }.by(0)

      expect(ProfileView.last.notified).to eq(false)
    end

    it "logs the view but sends no email when the parent disabled all notifications" do
      owner.update!(settings: (owner.settings || {}).merge("disable_notifications" => true))

      expect {
        job.perform(profile.id, "8.8.8.8", "UA")
      }.to change { ProfileView.count }.by(1).and change { deliveries }.by(0)
    end

    it "logs the view but sends no email when the communicator has no owner" do
      # A ChildAccount re-derives owner from user on save, so a truly ownerless
      # communicator also has no user.
      ownerless = FactoryBot.create(:child_account, user: nil, owner: nil)
      orphan = Profile.create!(profileable: ownerless, username: "no-owner", slug: "no-owner")

      expect {
        job.perform(orphan.id, "8.8.8.8", "UA")
      }.to change { ProfileView.count }.by(1).and change { deliveries }.by(0)
    end

    it "throttles to one email per profile per hour" do
      expect {
        job.perform(profile.id, "8.8.8.8", "UA")
        described_class.new.perform(profile.id, "9.9.9.9", "UA")
      }.to change { ProfileView.count }.by(2).and change { deliveries }.by(1)

      # Both views are logged; only the first is marked notified.
      expect(ProfileView.where(profile: profile, notified: true).count).to eq(1)
    end
  end
end
