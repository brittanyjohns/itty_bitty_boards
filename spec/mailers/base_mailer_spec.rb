require "rails_helper"

RSpec.describe BaseMailer, type: :mailer do
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
  end
end
