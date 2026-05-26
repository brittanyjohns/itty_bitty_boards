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
      expect(mail.subject).to eq("Welcome to the SpeakAnyWay Partner Program!")
      expect(mail.html_part.body.decoded).to include("Hi <strong>Pat</strong>")
      expect(mail.html_part.body.decoded).to include("SpeakAnyWay Pilot Partner Program")
      expect(mail.html_part.body.decoded).to include("GO TO PARTNER PORTAL")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.welcome_email(user).deliver_now
      expect(mail.subject).to eq("¡Te damos la bienvenida al Programa de Socios de SpeakAnyWay!")
      expect(mail.html_part.body.decoded).to include("Hola <strong>Pat</strong>")
      expect(mail.html_part.body.decoded).to include("Programa Piloto de Socios")
      expect(mail.html_part.body.decoded).to include("IR AL PORTAL DE SOCIOS")
    end

    it "falls back to English for an unsupported locale" do
      use_locale(user, "xx-YY")
      mail = described_class.welcome_email(user).deliver_now
      expect(mail.subject).to eq("Welcome to the SpeakAnyWay Partner Program!")
    end
  end
end
