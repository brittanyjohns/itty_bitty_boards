require "rails_helper"

RSpec.describe PartnerMailer, type: :mailer do
  def use_locale(user, lang)
    user.settings ||= {}
    user.settings["voice"] = { "language" => lang }
    user.save!
  end

  describe "#welcome_email" do
    let(:user) { FactoryBot.create(:user, name: "Pat") }

    it "renders the English subject and body" do
      use_locale(user, "en-US")
      mail = described_class.welcome_email(user).deliver_now
      expect(mail.subject).to eq("Welcome to the SpeakAnyWay Partner Program 💜")
      expect(mail.html_part.body.decoded).to include("Hi <strong>Pat</strong>")
      expect(mail.html_part.body.decoded).to include("SpeakAnyWay Partner Program")
      expect(mail.html_part.body.decoded).to include("Go to the Partner Portal")
    end

    it "does not use retired terminology (Pilot / MySpeak ID)" do
      use_locale(user, "en-US")
      body = described_class.welcome_email(user).deliver_now.html_part.body.decoded
      expect(body).not_to match(/Pilot/i)
      expect(body).not_to match(/MySpeak ID/i)
    end

    it "points the portal CTA at the app route by default" do
      use_locale(user, "en-US")
      body = described_class.welcome_email(user).deliver_now.html_part.body.decoded
      expect(body).to include("https://app.speakanyway.com/partner-portal")
      expect(body).not_to include("www.speakanyway.com/partner-portal")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.welcome_email(user).deliver_now
      expect(mail.subject).to eq("Te damos la bienvenida al Programa de Socios de SpeakAnyWay 💜")
      expect(mail.html_part.body.decoded).to include("Hola <strong>Pat</strong>")
      expect(mail.html_part.body.decoded).to include("Programa de Socios de SpeakAnyWay")
      expect(mail.html_part.body.decoded).to include("Ir al Portal de Socios")
    end

    it "falls back to English for an unsupported locale" do
      use_locale(user, "xx-YY")
      mail = described_class.welcome_email(user).deliver_now
      expect(mail.subject).to eq("Welcome to the SpeakAnyWay Partner Program 💜")
    end
  end

  describe "#pilot_ending_email" do
    let(:user) { FactoryBot.create(:user, name: "Pat", plan_type: "partner_pro") }

    before { user.update_columns(plan_expires_at: 10.days.from_now) }

    it "renders the English subject and body with the CTA" do
      use_locale(user, "en-US")
      mail = described_class.pilot_ending_email(user).deliver_now
      expect(mail.subject).to eq("Your SpeakAnyWay Partner pilot is wrapping up soon")
      expect(mail.html_part.body.decoded).to include("Hi <strong>Pat</strong>")
      expect(mail.html_part.body.decoded).to include("See plans &amp; continue")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.pilot_ending_email(user).deliver_now
      expect(mail.subject).to eq("Tu piloto de Socio de SpeakAnyWay está por terminar")
      expect(mail.html_part.body.decoded).to include("Hola <strong>Pat</strong>")
    end
  end
end
