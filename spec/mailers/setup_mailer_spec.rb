require "rails_helper"

RSpec.describe SetupMailer, type: :mailer do
  def use_locale(user, lang)
    user.settings ||= {}
    user.settings["voice"] = { "language" => lang }
    user.save!
  end

  describe "#myspeak_setup_email" do
    let(:user) { FactoryBot.create(:user, name: "Pat") }

    it "renders the English subject and body" do
      use_locale(user, "en-US")
      mail = described_class.myspeak_setup_email(user).deliver_now
      expect(mail.subject).to eq("MySpeak Setup Instructions")
      expect(mail.html_part.body.decoded).to include("Welcome to MySpeak!")
      expect(mail.html_part.body.decoded).to include("Hi Pat")
      expect(mail.html_part.body.decoded).to include("Your MySpeak Profile")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.myspeak_setup_email(user).deliver_now
      expect(mail.subject).to eq("Instrucciones para configurar MySpeak")
      expect(mail.html_part.body.decoded).to include("bienvenida a MySpeak")
      expect(mail.html_part.body.decoded).to include("Hola Pat")
      expect(mail.html_part.body.decoded).to include("Tu perfil de MySpeak")
    end
  end

  describe "#basic_setup_email" do
    let(:user) { FactoryBot.create(:user, name: "Pat") }

    it "renders the English subject and body" do
      use_locale(user, "en-US")
      mail = described_class.basic_setup_email(user).deliver_now
      expect(mail.subject).to eq("Basic Setup Instructions")
      expect(mail.html_part.body.decoded).to include("Welcome to SpeakAnyWay Basic!")
      expect(mail.html_part.body.decoded).to include("Hi Pat")
      expect(mail.html_part.body.decoded).to include("Get Started Now!")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.basic_setup_email(user).deliver_now
      expect(mail.subject).to eq("Instrucciones para configurar el plan Basic")
      expect(mail.html_part.body.decoded).to include("SpeakAnyWay Basic")
      expect(mail.html_part.body.decoded).to include("Hola Pat")
      expect(mail.html_part.body.decoded).to include("¡Empezar ahora!")
    end
  end

  describe "#pro_setup_email" do
    let(:user) { FactoryBot.create(:user, name: "Pat") }

    it "renders the English subject and body" do
      use_locale(user, "en-US")
      mail = described_class.pro_setup_email(user).deliver_now
      expect(mail.subject).to eq("Pro Setup Instructions")
      expect(mail.html_part.body.decoded).to include("Welcome to SpeakAnyWay Pro!")
      expect(mail.html_part.body.decoded).to include("Hi Pat")
      expect(mail.html_part.body.decoded).to include("Pro Account")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.pro_setup_email(user).deliver_now
      expect(mail.subject).to eq("Instrucciones para configurar el plan Pro")
      expect(mail.html_part.body.decoded).to include("SpeakAnyWay Pro")
      expect(mail.html_part.body.decoded).to include("Hola Pat")
      expect(mail.html_part.body.decoded).to include("cuenta Pro")
    end
  end

  describe "#vendor_setup_email" do
    let(:user) { FactoryBot.create(:user, name: "Pat") }

    it "renders the English subject and body" do
      use_locale(user, "en-US")
      mail = described_class.vendor_setup_email(user).deliver_now
      expect(mail.subject).to eq("Vendor Setup Instructions")
      expect(mail.html_part.body.decoded).to include("Welcome to SpeakAnyWay Vendor Hub!")
      expect(mail.html_part.body.decoded).to include("Hi Pat")
      expect(mail.html_part.body.decoded).to include("Set Up My Vendor Page")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.vendor_setup_email(user).deliver_now
      expect(mail.subject).to eq("Instrucciones para configurar tu cuenta de Proveedor")
      expect(mail.html_part.body.decoded).to include("Centro de Proveedores de SpeakAnyWay")
      expect(mail.html_part.body.decoded).to include("Hola Pat")
      expect(mail.html_part.body.decoded).to include("Configurar mi página de Proveedor")
    end
  end

  describe "fallback when user locale is unsupported" do
    let(:user) { FactoryBot.create(:user, name: "Pat") }

    it "falls back to English" do
      use_locale(user, "xx-YY")
      mail = described_class.basic_setup_email(user).deliver_now
      expect(mail.subject).to eq("Basic Setup Instructions")
    end
  end

  describe "name fallback" do
    let(:user) { FactoryBot.create(:user, name: nil) }

    it "renders a generic greeting when name is blank" do
      use_locale(user, "en-US")
      mail = described_class.basic_setup_email(user).deliver_now
      expect(mail.html_part.body.decoded).to include("Hi there,")
    end
  end
end
