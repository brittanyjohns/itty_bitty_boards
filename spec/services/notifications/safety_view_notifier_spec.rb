require "rails_helper"

RSpec.describe Notifications::SafetyViewNotifier do
  let(:owner) { FactoryBot.create(:user, email: "parent@example.com") }
  let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Sky") }
  let(:profile) { Profile.create!(profileable: child, username: "sky-notify", slug: "sky-notify") }
  let(:profile_view) { profile.profile_views.create!(approx_location: "Austin, Texas, US") }

  describe ".deliver" do
    it "sends the parent the viewed-alert email" do
      expect {
        described_class.deliver(profile: profile, profile_view: profile_view, owner: owner)
      }.to change { ActionMailer::Base.deliveries.size }.by(1)

      expect(ActionMailer::Base.deliveries.last.to).to eq([owner.email])
    end

    it "does not send email when the owner has no email" do
      allow(owner).to receive(:email).and_return(nil)
      expect {
        described_class.deliver(profile: profile, profile_view: profile_view, owner: owner)
      }.not_to change { ActionMailer::Base.deliveries.size }
    end

    it "the push channel is a no-op stub today" do
      notifier = described_class.new(profile: profile, profile_view: profile_view, owner: owner)
      expect(notifier.send(:push_enabled?)).to eq(false)
      # deliver_push must not raise and must not deliver anything
      expect { notifier.send(:deliver_push) }.not_to change { ActionMailer::Base.deliveries.size }
    end
  end
end
