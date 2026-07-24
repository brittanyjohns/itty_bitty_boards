require "rails_helper"

RSpec.describe AdminMailer, type: :mailer do
  describe "#disk_space_alert" do
    it "addresses the admin and renders a WARNING subject and body" do
      mail = described_class.disk_space_alert(usage: 85, severity: :warn).deliver_now

      expect(mail.to).to eq([ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"])
      expect(mail.subject).to eq("[WARNING] SpeakAnyWay server disk at 85%")
      expect(mail.html_part.body.decoded).to include("85%")
      expect(mail.html_part.body.decoded).to include("WARN")
    end

    it "uses a CRITICAL subject for critical severity" do
      mail = described_class.disk_space_alert(usage: 93, severity: :critical).deliver_now

      expect(mail.subject).to eq("[CRITICAL] SpeakAnyWay server disk at 93%")
      expect(mail.html_part.body.decoded).to include("CRITICAL")
    end
  end

  describe "#partner_pilot_review" do
    it "addresses the admin, summarizes counts, and lists both groups" do
      expiring = FactoryBot.create(:user, name: "Soon", email: "soon@example.com", plan_type: "partner_pro")
      expiring.update_columns(plan_expires_at: 5.days.from_now)
      expired = FactoryBot.create(:user, name: "Past", email: "past@example.com", plan_type: "partner_pro")
      expired.update_columns(plan_expires_at: 3.days.ago)

      mail = described_class.partner_pilot_review(expiring: [expiring], expired: [expired]).deliver_now

      expect(mail.to).to eq([ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"])
      expect(mail.subject).to eq("Partner pilots: 1 ended, 1 ending soon")
      body = mail.html_part.body.decoded
      expect(body).to include("soon@example.com")
      expect(body).to include("past@example.com")
    end

    it "renders cleanly when a group is empty" do
      mail = described_class.partner_pilot_review(expiring: [], expired: []).deliver_now
      expect(mail.subject).to eq("Partner pilots: 0 ended, 0 ending soon")
      expect(mail.html_part.body.decoded).to include("None.")
    end
  end

  describe "#new_user_email" do
    let(:user) do
      FactoryBot.create(:user, name: "Jane Doe", email: "jane@example.com", plan_type: "free").tap do |u|
        u.update_columns(stripe_customer_id: "cus_ABC123", current_sign_in_ip: "8.8.8.8")
        u.record_signup_context!(platform: "ios", method: "standard")
      end
    end

    before { allow(IpGeolocation).to receive(:coarse).and_return(nil) }

    it "puts the email, plan, and platform in the subject" do
      mail = described_class.new_user_email(user).deliver_now
      expect(mail.to).to eq([ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"])
      expect(mail.subject).to eq("New signup: jane@example.com (free · ios)")
    end

    it "renders the signup context and omits the legacy tokens field" do
      body = described_class.new_user_email(user).deliver_now.html_part.body.decoded
      expect(body).to include("jane@example.com")
      expect(body).to include("standard")
      expect(body).to include("ios")
      expect(body).not_to match(/Tokens:/i)
    end

    it "links to the admin dashboard and the Stripe customer" do
      body = described_class.new_user_email(user).deliver_now.html_part.body.decoded
      expect(body).to include("/admin/users/#{user.id}")
      expect(body).to include("https://dashboard.stripe.com/customers/cus_ABC123")
    end

    it "omits the Stripe subscription link when there is no subscription" do
      body = described_class.new_user_email(user).deliver_now.html_part.body.decoded
      expect(body).not_to include("dashboard.stripe.com/subscriptions")
    end

    it "includes the Stripe subscription link when there is one" do
      user.update_columns(stripe_subscription_id: "sub_XYZ789")
      body = described_class.new_user_email(user).deliver_now.html_part.body.decoded
      expect(body).to include("https://dashboard.stripe.com/subscriptions/sub_XYZ789")
    end

    it "renders a coarse location when the lookup succeeds" do
      allow(IpGeolocation).to receive(:coarse).with("8.8.8.8")
        .and_return({ city: "Austin", region: "Texas", country: "US", label: "Austin, Texas, US" })
      body = described_class.new_user_email(user).deliver_now.html_part.body.decoded
      expect(body).to include("Austin, Texas, US")
    end

    it "omits the location row when the lookup returns nil" do
      body = described_class.new_user_email(user).deliver_now.html_part.body.decoded
      expect(body).not_to match(/Location/i)
    end

    it "renders unknown for an account with no captured signup context" do
      legacy = FactoryBot.create(:user, email: "legacy@example.com")
      body = described_class.new_user_email(legacy).deliver_now.html_part.body.decoded
      expect(body).to include("unknown")
    end

    it "prefixes the subject on staging" do
      allow(AppEnv).to receive(:staging?).and_return(true)
      expect(described_class.new_user_email(user).subject).to start_with("[STAGING] ")
    end
  end
end
