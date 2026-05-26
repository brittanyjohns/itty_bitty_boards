require "rails_helper"

RSpec.describe BaseMailer, type: :mailer do
  def use_locale(user, lang)
    user.settings ||= {}
    user.settings["voice"] = { "language" => lang }
    user.save!
  end

  describe "#team_invitation_email" do
    let(:inviter) { FactoryBot.create(:user, name: "Alex Reed") }
    let(:invitee) { FactoryBot.create(:user, name: "Sam Carter") }
    let(:team) { Team.create!(name: "Speech Crew", created_by: inviter) }

    it "renders the subject, sender, and recipient" do
      mail = described_class.team_invitation_email(invitee, inviter, team).deliver_now

      expect(mail.subject).to eq("You have been invited to join a team on SpeakAnyWay AAC!")
      expect(mail.to).to eq([invitee.email])
      expect(mail.from).to eq(["noreply@speakanyway.com"])
    end

    it "renders the team name, invitee name, and an invitation link in the body" do
      mail = described_class.team_invitation_email(invitee, inviter, team).deliver_now
      body = mail.html_part.body.decoded

      expect(body).to include("Speech Crew")
      expect(body).to include("Sam Carter")
      expect(body).to include("/accept-invite/#{team.id}/#{invitee.uuid}")
    end

    it "stamps invitation_sent_at on the invitee" do
      expect {
        described_class.team_invitation_email(invitee, inviter, team).deliver_now
      }.to change { invitee.reload.invitation_sent_at }.from(nil)
    end

    context "when the invitee prefers Spanish" do
      before { use_locale(invitee, "es-US") }

      it "renders the Spanish subject and body" do
        mail = described_class.team_invitation_email(invitee, inviter, team).deliver_now
        body = mail.html_part.body.decoded

        expect(mail.subject).to eq("¡Te han invitado a unirte a un equipo en SpeakAnyWay AAC!")
        expect(body).to include("Hola Sam Carter")
        expect(body).to include("Aceptar invitación")
        expect(body).to include("Speech Crew")
        expect(body).to include("Alex Reed")
      end
    end

    context "when the invitee prefers an unsupported locale" do
      before { use_locale(invitee, "xx-YY") }

      it "falls back to English" do
        mail = described_class.team_invitation_email(invitee, inviter, team).deliver_now
        expect(mail.subject).to eq("You have been invited to join a team on SpeakAnyWay AAC!")
      end
    end

    context "when the invitee has no name" do
      let(:invitee) { FactoryBot.create(:user, name: nil) }

      it "renders a generic greeting" do
        mail = described_class.team_invitation_email(invitee, inviter, team).deliver_now
        expect(mail.html_part.body.decoded).to include("Hi there,")
      end
    end
  end
end
