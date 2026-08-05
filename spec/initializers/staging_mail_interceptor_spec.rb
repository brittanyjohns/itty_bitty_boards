require "rails_helper"

RSpec.describe StagingMailInterceptor do
  def message_to(*recipients, cc: nil, bcc: nil)
    Mail::Message.new.tap do |m|
      m.to = recipients
      m.cc = cc if cc
      m.bcc = bcc if bcc
    end
  end

  def staging!(allowlist: nil)
    allow(AppEnv).to receive(:staging?).and_return(true)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("STAGING_MAIL_ALLOWLIST").and_return(allowlist)
  end

  context "outside staging" do
    it "leaves mail alone" do
      allow(AppEnv).to receive(:staging?).and_return(false)
      message = message_to("parent@example.com")

      described_class.delivering_email(message)

      expect(message.perform_deliveries).to be true
      expect(message.to).to eq(["parent@example.com"])
    end
  end

  context "on staging with no allowlist" do
    before { staging! }

    it "blocks delivery" do
      message = message_to("parent@example.com")

      described_class.delivering_email(message)

      expect(message.perform_deliveries).to be false
    end

    it "blocks delivery to cc and bcc recipients too" do
      message = message_to("parent@example.com", cc: "slp@example.com", bcc: "admin@example.com")

      described_class.delivering_email(message)

      expect(message.perform_deliveries).to be false
    end
  end

  context "on staging with an allowlist" do
    it "delivers to an exactly allowlisted address" do
      staging!(allowlist: "brittany@speakanyway.com")
      message = message_to("brittany@speakanyway.com")

      described_class.delivering_email(message)

      expect(message.perform_deliveries).to be true
      expect(message.to).to eq(["brittany@speakanyway.com"])
    end

    it "matches case-insensitively and ignores surrounding whitespace" do
      staging!(allowlist: " Brittany@SpeakAnyWay.com , other@example.com ")
      message = message_to("brittany@speakanyway.com")

      described_class.delivering_email(message)

      expect(message.perform_deliveries).to be true
    end

    it "allows a whole domain with an @-prefixed entry" do
      staging!(allowlist: "@speakanyway.com")
      message = message_to("anyone@speakanyway.com")

      described_class.delivering_email(message)

      expect(message.perform_deliveries).to be true
    end

    it "strips non-allowlisted recipients but still delivers to allowlisted ones" do
      staging!(allowlist: "@speakanyway.com")
      message = message_to("parent@example.com", "brittany@speakanyway.com")

      described_class.delivering_email(message)

      expect(message.perform_deliveries).to be true
      expect(message.to).to eq(["brittany@speakanyway.com"])
    end

    it "strips non-allowlisted cc and bcc recipients" do
      staging!(allowlist: "brittany@speakanyway.com")
      message = message_to("brittany@speakanyway.com", cc: "slp@example.com", bcc: "admin@example.com")

      described_class.delivering_email(message)

      expect(message.perform_deliveries).to be true
      expect(message.to).to eq(["brittany@speakanyway.com"])
      expect(message.cc).to be_nil
      expect(message.bcc).to be_nil
    end

    it "drops mail when no recipient is allowlisted" do
      staging!(allowlist: "brittany@speakanyway.com")
      message = message_to("parent@example.com")

      described_class.delivering_email(message)

      expect(message.perform_deliveries).to be false
    end

    it "does not treat a domain entry as a substring match on other domains" do
      staging!(allowlist: "@speakanyway.com")
      message = message_to("parent@speakanyway.com.evil.com")

      described_class.delivering_email(message)

      expect(message.perform_deliveries).to be false
    end
  end
end
