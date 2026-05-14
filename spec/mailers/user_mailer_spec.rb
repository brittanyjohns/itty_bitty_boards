require "rails_helper"

RSpec.describe UserMailer, type: :mailer do
  describe "#welcome_email" do
    let(:user) { FactoryBot.create(:user, name: "Pat") }

    context "when the user prefers English" do
      before do
        user.settings ||= {}
        user.settings["voice"] = { "language" => "en-US" }
        user.save!
      end

      it "renders the English subject and body" do
        mail = described_class.welcome_email(user).deliver_now
        expect(mail.subject).to eq("Welcome to SpeakAnyWay AAC!")
        expect(mail.html_part.body.decoded).to include("Welcome to SpeakAnyWay")
        expect(mail.html_part.body.decoded).to include("Hi Pat")
        expect(mail.html_part.body.decoded).to include("Go to Your Dashboard")
      end
    end

    context "when the user prefers Spanish" do
      before do
        user.settings ||= {}
        user.settings["voice"] = { "language" => "es-US" }
        user.save!
      end

      it "renders the Spanish subject and body" do
        mail = described_class.welcome_email(user).deliver_now
        expect(mail.subject).to eq("¡Bienvenido a SpeakAnyWay AAC!")
        expect(mail.html_part.body.decoded).to include("Bienvenido a SpeakAnyWay")
        expect(mail.html_part.body.decoded).to include("Hola Pat")
        expect(mail.html_part.body.decoded).to include("Ir a tu Panel")
      end
    end

    context "when the user prefers an unsupported language" do
      before do
        user.settings ||= {}
        user.settings["voice"] = { "language" => "xx-YY" }
        user.save!
      end

      it "falls back to English" do
        mail = described_class.welcome_email(user).deliver_now
        expect(mail.subject).to eq("Welcome to SpeakAnyWay AAC!")
      end
    end
  end
end
