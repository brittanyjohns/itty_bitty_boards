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
end
