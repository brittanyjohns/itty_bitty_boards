require "rails_helper"

RSpec.describe ApplicationMailer, type: :mailer do
  describe ".email_logo_url" do
    it "points at the logo shipped in public/" do
      expect(described_class.email_logo_url).to end_with("/email-logo.png")
      expect(Rails.root.join("public", described_class::EMAIL_LOGO_FILENAME)).to exist
    end

    it "prefers an explicit EMAIL_LOGO_URL so the logo can move to a CDN" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("EMAIL_LOGO_URL").and_return("https://cdn.example.com/logo.png")

      expect(described_class.email_logo_url).to eq("https://cdn.example.com/logo.png")
    end

    it "builds an absolute URL from the mailer host" do
      allow(ActionMailer::Base).to receive(:default_url_options)
        .and_return({ host: "mail.example.com", protocol: "https" })

      expect(described_class.email_logo_url).to eq("https://mail.example.com/email-logo.png")
    end

    it "keeps the port when the mailer host carries one" do
      allow(ActionMailer::Base).to receive(:default_url_options)
        .and_return({ host: "localhost", port: 4000, protocol: "http" })

      expect(described_class.email_logo_url).to eq("http://localhost:4000/email-logo.png")
    end
  end

  describe "logo delivery" do
    # The logo must never be an attachment: mail clients list every attachment
    # part in the attachment strip, including inline (cid) parts the HTML
    # already references, which made the logo look like a downloadable file.
    it "never attaches the logo to a message" do
      user = FactoryBot.create(:user, name: "Ash")

      mails = [
        UserMailer.subscription_canceled_email(user),
        UserMailer.payment_failed_email(user),
        UserMailer.welcome_email(user),
        UserMailer.delete_account_email(user),
      ]

      mails.each do |mail|
        expect(mail.attachments).to be_empty, "#{mail.subject.inspect} carried an attachment"
        expect(mail.body.encoded).not_to include("cid:")
      end
    end

    it "exposes the logo to templates as a URL" do
      expect(UserMailer.new.instance_variable_get(:@logo).url)
        .to eq(described_class.email_logo_url)
    end
  end
end
