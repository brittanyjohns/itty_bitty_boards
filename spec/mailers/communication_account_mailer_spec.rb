require "rails_helper"

RSpec.describe CommunicationAccountMailer, type: :mailer do
  def use_locale(user, lang)
    user.settings ||= {}
    user.settings["voice"] = { "language" => lang }
    user.save!
  end

  let(:owner) { FactoryBot.create(:user, name: "Alex Reed") }
  let(:account) do
    FactoryBot.create(
      :child_account,
      user: owner,
      owner: owner,
      name: "Sam Carter",
      passcode: "abc12345",
      settings: { "email" => "sam@example.com" },
    )
  end

  describe "#setup_email" do
    it "renders the English subject and body" do
      use_locale(owner, "en-US")
      mail = described_class.setup_email(account, owner).deliver_now

      expect(mail.subject).to eq("Welcome to SpeakAnyWay AAC!")
      expect(mail.to).to eq(["sam@example.com"])
      body = mail.html_part.body.decoded
      expect(body).to include("You have a new account on SpeakAnyWay!")
      expect(body).to include("Hi Sam Carter")
      expect(body).to include("Alex Reed")
      expect(body).to include("abc12345")
      expect(body).to include("Set Up Account")
    end

    it "renders the Spanish subject and body when the owner prefers Spanish" do
      use_locale(owner, "es-US")
      mail = described_class.setup_email(account, owner).deliver_now

      expect(mail.subject).to eq("¡Te damos la bienvenida a SpeakAnyWay AAC!")
      body = mail.html_part.body.decoded
      expect(body).to include("¡Tienes una nueva cuenta en SpeakAnyWay!")
      expect(body).to include("Hola Sam Carter")
      expect(body).to include("Configurar cuenta")
    end

    context "when the account has no owner" do
      let(:account) do
        FactoryBot.create(
          :child_account,
          user: nil,
          owner: nil,
          name: "Sam Carter",
          passcode: "abc12345",
          settings: { "email" => "sam@example.com" },
        )
      end

      it "falls back to English" do
        mail = described_class.setup_email(account, owner).deliver_now
        expect(mail.subject).to eq("Welcome to SpeakAnyWay AAC!")
      end
    end
  end

  describe "#claim_link_email" do
    it "renders the English subject with the owner name interpolated" do
      use_locale(owner, "en-US")
      mail = described_class.claim_link_email(account, "parent@example.com", owner).deliver_now

      expect(mail.subject).to eq("Alex Reed sent you a SpeakAnyWay communicator")
      expect(mail.to).to eq(["parent@example.com"])
      body = mail.html_part.body.decoded
      expect(body).to include("Alex Reed")
      expect(body).to include("Sam Carter")
      expect(body).to include("Claim the communicator")
    end

    it "renders the Spanish subject and body when the owner prefers Spanish" do
      use_locale(owner, "es-US")
      mail = described_class.claim_link_email(account, "parent@example.com", owner).deliver_now

      expect(mail.subject).to eq("Alex Reed te envió un comunicador de SpeakAnyWay")
      body = mail.html_part.body.decoded
      expect(body).to include("Haz tuyo el comunicador de Sam Carter")
      expect(body).to include("Reclamar el comunicador")
    end

    context "when there is no sending user or owner" do
      let(:account) do
        FactoryBot.create(
          :child_account,
          user: nil,
          owner: nil,
          name: "Sam Carter",
          passcode: "abc12345",
          settings: { "email" => "sam@example.com" },
        )
      end

      it "uses the default 'Your therapist' fallback" do
        mail = described_class.claim_link_email(account, "parent@example.com", nil).deliver_now
        expect(mail.subject).to eq("Your therapist sent you a SpeakAnyWay communicator")
      end
    end
  end

  describe "#safety_cards_updated" do
    it "addresses the owner and links to the communicator's safety page" do
      mail = described_class.safety_cards_updated(owner, account).deliver_now

      expect(mail.to).to eq([owner.email])
      expect(mail.subject).to eq("Sam Carter's safety cards have been updated")
      body = mail.html_part&.body&.decoded || mail.body.decoded
      expect(body).to include("Sam Carter")
      expect(body).to include("/communicators/#{account.id}/safety")
    end
  end
end
