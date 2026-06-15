require "rails_helper"

RSpec.describe UserMailer, type: :mailer do
  def use_locale(user, lang)
    user.settings ||= {}
    user.settings["voice"] = { "language" => lang }
    user.save!
  end

  describe "#welcome_email" do
    let(:user) { FactoryBot.create(:user, name: "Pat") }

    context "when the user prefers English" do
      before { use_locale(user, "en-US") }

      it "renders the English subject and body" do
        mail = described_class.welcome_email(user).deliver_now
        expect(mail.subject).to eq("Welcome to SpeakAnyWay AAC!")
        expect(mail.html_part.body.decoded).to include("Welcome to SpeakAnyWay")
        expect(mail.html_part.body.decoded).to include("Hi Pat")
        expect(mail.html_part.body.decoded).to include("Go to Your Dashboard")
      end
    end

    context "when the user prefers Spanish" do
      before { use_locale(user, "es-US") }

      it "renders the Spanish subject and body" do
        mail = described_class.welcome_email(user).deliver_now
        expect(mail.subject).to eq("¡Bienvenido a SpeakAnyWay AAC!")
        expect(mail.html_part.body.decoded).to include("Bienvenido a SpeakAnyWay")
        expect(mail.html_part.body.decoded).to include("Hola Pat")
        expect(mail.html_part.body.decoded).to include("Ir a tu Panel")
      end
    end

    context "when the user prefers an unsupported language" do
      before { use_locale(user, "xx-YY") }

      it "falls back to English" do
        mail = described_class.welcome_email(user).deliver_now
        expect(mail.subject).to eq("Welcome to SpeakAnyWay AAC!")
      end
    end
  end

  describe "#welcome_free_email" do
    let(:user) { FactoryBot.create(:user, name: "Pat") }

    it "renders the English subject and body" do
      use_locale(user, "en-US")
      mail = described_class.welcome_free_email(user).deliver_now
      expect(mail.subject).to eq("Welcome to SpeakAnyWay AAC!")
      expect(mail.html_part.body.decoded).to include("Free plan")
      expect(mail.html_part.body.decoded).to include("Log In &amp; Start Exploring")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.welcome_free_email(user).deliver_now
      expect(mail.subject).to eq("¡Bienvenido a SpeakAnyWay AAC!")
      expect(mail.html_part.body.decoded).to include("Plan Gratis")
      expect(mail.html_part.body.decoded).to include("Inicia sesión y empieza a explorar")
    end

    # The raw invitation token must travel as an explicit argument — the
    # virtual attr on the user is nil after deliver_later's GlobalID
    # round-trip, which is why the magic link never rendered before.
    it "links to the magic-link welcome page when a raw invitation token is passed" do
      use_locale(user, "en-US")
      mail = described_class.welcome_free_email(user, "RAWTOKEN123").deliver_now
      expect(mail.html_part.body.decoded).to include("/welcome/token/RAWTOKEN123")
    end

    it "falls back to the sign-in link without a token (pins current behavior)" do
      use_locale(user, "en-US")
      mail = described_class.welcome_free_email(user).deliver_now
      body = mail.html_part.body.decoded
      expect(body).to include("/users/sign-in")
      expect(body).not_to include("/welcome/token/")
    end
  end

  describe "#welcome_basic_email" do
    let(:user) { FactoryBot.create(:user, name: "Pat") }

    it "renders the English subject and body" do
      use_locale(user, "en-US")
      mail = described_class.welcome_basic_email(user).deliver_now
      expect(mail.subject).to eq("Welcome to SpeakAnyWay AAC — Basic plan")
      expect(mail.html_part.body.decoded).to include("Basic plan")
      expect(mail.html_part.body.decoded).to include("Open Your Dashboard")
      expect(mail.html_part.body.decoded).to include("Hi Pat")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.welcome_basic_email(user).deliver_now
      expect(mail.subject).to eq("Bienvenido a SpeakAnyWay AAC — plan Basic")
      expect(mail.html_part.body.decoded).to include("Plan Basic")
      expect(mail.html_part.body.decoded).to include("Abre tu Panel")
      expect(mail.html_part.body.decoded).to include("Hola Pat")
    end
  end

  describe "#welcome_pro_email" do
    let(:user) { FactoryBot.create(:user, name: "Pat") }

    it "renders the English subject and body" do
      use_locale(user, "en-US")
      mail = described_class.welcome_pro_email(user).deliver_now
      expect(mail.subject).to eq("Welcome to SpeakAnyWay AAC — Pro plan")
      expect(mail.html_part.body.decoded).to include("Welcome to SpeakAnyWay Pro")
      expect(mail.html_part.body.decoded).to include("Open Your Pro Dashboard")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.welcome_pro_email(user).deliver_now
      expect(mail.subject).to eq("Bienvenido a SpeakAnyWay AAC — plan Pro")
      expect(mail.html_part.body.decoded).to include("Bienvenido a SpeakAnyWay Pro")
      expect(mail.html_part.body.decoded).to include("Abre tu Panel Pro")
    end
  end

  describe "#welcome_invitation_email" do
    let(:inviter) { FactoryBot.create(:user, name: "Sam") }
    let(:invitee) do
      User.invite!(email: "invitee@example.com", name: "Pat") { |u| u.skip_invitation = true }
    end

    it "renders the English subject and body" do
      use_locale(invitee, "en-US")
      mail = described_class.welcome_invitation_email(invitee, inviter.id).deliver_now
      expect(mail.subject).to eq("You have been invited to join SpeakAnyWay AAC!")
      expect(mail.html_part.body.decoded).to include("You&#39;ve Been Invited")
      expect(mail.html_part.body.decoded).to include("Sam")
      expect(mail.html_part.body.decoded).to include("Finish Setting Up Your Account")
    end

    it "renders the Spanish subject and body" do
      use_locale(invitee, "es-US")
      mail = described_class.welcome_invitation_email(invitee, inviter.id).deliver_now
      expect(mail.subject).to eq("¡Te han invitado a unirte a SpeakAnyWay AAC!")
      expect(mail.html_part.body.decoded).to include("¡Te han invitado!")
      expect(mail.html_part.body.decoded).to include("Sam")
      expect(mail.html_part.body.decoded).to include("Termina de configurar tu cuenta")
    end
  end

  describe "#welcome_new_vendor_email" do
    let(:user) { FactoryBot.create(:user, name: "Pat") }
    let(:vendor) { FactoryBot.create(:vendor, business_name: "Cafe Acme", category: "Food & Beverage") }

    it "renders the English subject and body" do
      use_locale(user, "en-US")
      mail = described_class.welcome_new_vendor_email(user, vendor).deliver_now
      expect(mail.subject).to eq("Welcome to SpeakAnyWay AAC - Cafe Acme!")
      expect(mail.html_part.body.decoded).to include("Welcome to SpeakAnyWay, Cafe Acme")
      expect(mail.html_part.body.decoded).to include("View Your Setup Guide to Get Started")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.welcome_new_vendor_email(user, vendor).deliver_now
      expect(mail.subject).to eq("¡Bienvenido a SpeakAnyWay AAC - Cafe Acme!")
      expect(mail.html_part.body.decoded).to include("¡Bienvenido a SpeakAnyWay, Cafe Acme")
      expect(mail.html_part.body.decoded).to include("Ver la Guía de Configuración para Empezar")
    end
  end

  describe "#welcome_to_organization_email" do
    let(:admin_user) { FactoryBot.create(:user, name: "Admin Alex") }
    let(:organization) { Organization.create!(name: "Acme Org", slug: "acme-org", admin_user_id: admin_user.id) }
    let(:user) { FactoryBot.create(:user, name: "Pat") }

    it "renders the English subject and body" do
      use_locale(user, "en-US")
      mail = described_class.welcome_to_organization_email(user, organization).deliver_now
      expect(mail.subject).to eq("You have been invited to join Acme Org on SpeakAnyWay AAC!")
      expect(mail.html_part.body.decoded).to include("Acme Org")
      expect(mail.html_part.body.decoded).to include("Admin Alex")
      expect(mail.html_part.body.decoded).to include("Finish Setting Up Your Account")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.welcome_to_organization_email(user, organization).deliver_now
      expect(mail.subject).to eq("¡Te han invitado a unirte a Acme Org en SpeakAnyWay AAC!")
      expect(mail.html_part.body.decoded).to include("Acme Org")
      expect(mail.html_part.body.decoded).to include("Admin Alex")
      expect(mail.html_part.body.decoded).to include("Termina de configurar tu cuenta")
    end
  end

  describe "#welcome_with_claim_link_email" do
    let(:user) do
      User.invite!(email: "claimer@example.com", name: "Pat") { |u| u.skip_invitation = true }
    end

    it "renders the English subject and body" do
      use_locale(user, "en-US")
      mail = described_class.welcome_with_claim_link_email(user, "demo-slug").deliver_now
      expect(mail.subject).to eq("Welcome to MySpeak - Claim your profile!")
      expect(mail.html_part.body.decoded).to include("Welcome to MySpeak")
      expect(mail.html_part.body.decoded).to include("Open MySpeak")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.welcome_with_claim_link_email(user, "demo-slug").deliver_now
      expect(mail.subject).to eq("Bienvenido a MySpeak: ¡reclama tu perfil!")
      expect(mail.html_part.body.decoded).to include("Bienvenido a MySpeak")
      expect(mail.html_part.body.decoded).to include("Abrir MySpeak")
    end
  end

  describe "#delete_account_email" do
    let(:user) { FactoryBot.create(:user, name: "Pat") }

    it "renders the English subject and body" do
      use_locale(user, "en-US")
      mail = described_class.delete_account_email(user).deliver_now
      expect(mail.subject).to eq("Confirm Your SpeakAnyWay AAC Account Deletion")
      expect(mail.html_part.body.decoded).to include("Hi Pat")
      expect(mail.html_part.body.decoded).to include("Confirm account deletion")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.delete_account_email(user).deliver_now
      expect(mail.subject).to eq("Confirma la eliminación de tu cuenta de SpeakAnyWay AAC")
      expect(mail.html_part.body.decoded).to include("Hola Pat")
      expect(mail.html_part.body.decoded).to include("Confirmar la eliminación de la cuenta")
    end
  end

  describe "#confirm_update_email" do
    let(:user) { FactoryBot.create(:user, name: "Pat") }

    before do
      # confirm_update_email reloads and requires a confirmation_token + unconfirmed_email.
      # Use update_columns to bypass any Devise callbacks that would munge the token.
      user.update_columns(unconfirmed_email: "new@example.com", confirmation_token: "token-123")
    end

    it "renders the English subject and body" do
      use_locale(user, "en-US")
      mail = described_class.confirm_update_email(user).deliver_now
      expect(mail.subject).to eq("Confirm your SpeakAnyWay email update")
      body = (mail.html_part || mail).body.decoded
      expect(body).to include("Hello #{user.email}")
      expect(body).to include("Confirm email update")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.confirm_update_email(user).deliver_now
      expect(mail.subject).to eq("Confirma la actualización de tu correo en SpeakAnyWay")
      body = (mail.html_part || mail).body.decoded
      expect(body).to include("¡Hola #{user.email}")
      expect(body).to include("Confirmar actualización de correo")
    end
  end

  describe "#temporary_login_email" do
    let(:user) { FactoryBot.create(:user, name: "Pat") }

    before { user.update!(temp_login_token: "temp-token-123") }

    it "renders the English subject and body" do
      use_locale(user, "en-US")
      mail = described_class.temporary_login_email(user, 24).deliver_now
      expect(mail.subject).to eq("Your Temporary Login Link for SpeakAnyWay AAC")
      expect(mail.html_part.body.decoded).to include("Temporary login to SpeakAnyWay")
      expect(mail.html_part.body.decoded).to include("Log in to SpeakAnyWay")
      expect(mail.html_part.body.decoded).to include("Expires in 24 hours")
    end

    it "renders the Spanish subject and body" do
      use_locale(user, "es-US")
      mail = described_class.temporary_login_email(user, 24).deliver_now
      expect(mail.subject).to eq("Tu enlace de inicio de sesión temporal para SpeakAnyWay AAC")
      expect(mail.html_part.body.decoded).to include("Inicio de sesión temporal en SpeakAnyWay")
      expect(mail.html_part.body.decoded).to include("Iniciar sesión en SpeakAnyWay")
      expect(mail.html_part.body.decoded).to include("Caduca en 24 horas")
    end
  end

  describe "#message_notification_email" do
    let(:sender) { FactoryBot.create(:user, name: "Sam") }
    let(:recipient) { FactoryBot.create(:user, name: "Pat") }
    let(:message) do
      Message.create!(sender: sender, recipient: recipient, subject: "Hi", body: "hello", sent_at: Time.current)
    end

    it "renders the English subject and body using recipient's locale" do
      use_locale(recipient, "en-US")
      use_locale(sender, "es-US") # sender locale should NOT be used
      mail = described_class.message_notification_email(message).deliver_now
      expect(mail.subject).to eq("New message from Sam")
      expect(mail.html_part.body.decoded).to include("You&#39;ve Got Mail")
      expect(mail.html_part.body.decoded).to include("View Message")
    end

    it "renders the Spanish subject and body using recipient's locale" do
      use_locale(recipient, "es-US")
      use_locale(sender, "en-US") # sender locale should NOT be used
      mail = described_class.message_notification_email(message).deliver_now
      expect(mail.subject).to eq("Nuevo mensaje de Sam")
      expect(mail.html_part.body.decoded).to include("¡Tienes correo!")
      expect(mail.html_part.body.decoded).to include("Ver mensaje")
    end
  end
end
