require "rails_helper"

RSpec.describe SafetyProfileMailer, type: :mailer do
  let(:owner) { FactoryBot.create(:user, email: "parent@example.com") }
  let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Sky") }
  let(:profile) { Profile.create!(profileable: child, username: "sky-mail", slug: "sky-mail") }

  describe "#viewed_alert" do
    it "addresses the parent and names the child in the subject" do
      view = profile.profile_views.create!(viewed_at: Time.utc(2026, 6, 24, 15, 5))
      mail = described_class.viewed_alert(profile, view)

      expect(mail.to).to eq([owner.email])
      expect(mail.subject).to include("Sky")
    end

    it "includes the timestamp and renders without a location when none was captured" do
      view = profile.profile_views.create!(viewed_at: Time.utc(2026, 6, 24, 15, 5))
      mail = described_class.viewed_alert(profile, view)
      body = mail.body.encoded

      expect(body).to include("June 24, 2026")
      expect(body).not_to include("Approximate location")
    end

    it "includes the approximate location when present" do
      view = profile.profile_views.create!(
        viewed_at: Time.utc(2026, 6, 24, 15, 5),
        approx_location: "Austin, Texas, US",
      )
      body = described_class.viewed_alert(profile, view).body.encoded

      expect(body).to include("Austin, Texas, US")
    end

    it "links the CTA to the dashboard, not a nonexistent myspeak route" do
      view = profile.profile_views.create!(viewed_at: Time.utc(2026, 6, 24, 15, 5))
      body = described_class.viewed_alert(profile, view).body.encoded

      expect(body).to include("/dashboard")
      expect(body).not_to include("/dashboard/myspeak")
    end

    it "embeds the SpeakAnyWay logo inline rather than as a file attachment" do
      view = profile.profile_views.create!(viewed_at: Time.utc(2026, 6, 24, 15, 5))
      mail = described_class.viewed_alert(profile, view)

      logo = mail.attachments["logo.png"]
      expect(logo).to be_present
      expect(logo.inline?).to be(true)
      # The HTML references the logo by its content-id so clients render it in
      # the body instead of listing it as a downloadable attachment.
      expect(mail.html_part.body.encoded).to include(logo.cid)
    end

    it "does not attach the MySpeak logo" do
      view = profile.profile_views.create!(viewed_at: Time.utc(2026, 6, 24, 15, 5))
      mail = described_class.viewed_alert(profile, view)

      expect(mail.attachments.map(&:filename)).not_to include("myspeak_logo.png")
    end

    it "does not deliver when the profile has no owner" do
      orphan = Profile.create!(username: "orphan-1", slug: "orphan-1")
      view = ProfileView.create!(profile: orphan)
      mail = described_class.viewed_alert(orphan, view)
      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end
  end
end
