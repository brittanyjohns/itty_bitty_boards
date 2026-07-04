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
end
