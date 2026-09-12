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
      body = (mail.html_part || mail).body.decoded

      expect(body).to include("Speech Crew")
      expect(body).to include("Sam Carter")
      expect(body).to include("/accept-invite/#{team.id}/#{invitee.uuid}")
    end

    # #915. Which of the two link shapes an invitee gets decides whether the
    # invitation is usable at all, and it is chosen from `raw_invitation_token`
    # — readable only on the instance that just minted it.
    describe "the invitation link" do
      def link_in(mail)
        body = (mail.html_part || mail).body.decoded
        body[%r{https?://[^"']*/(?:invite/token|accept-invite)/[^"']+}]
      end

      it "sends an invitee with no password to the set-password page, carrying the team" do
        pending_invitee = User.invite!(email: "brand.new@example.com") { |u| u.skip_invitation = true }

        mail = described_class.team_invitation_email(pending_invitee, inviter, team).deliver_now

        link = link_in(mail)
        expect(link).to include("/invite/token/#{pending_invitee.raw_invitation_token}")
        expect(link).to include("team_id=#{team.id}")
        expect(link).to include("email=brand.new%40example.com")
      end

      it "sends an invitee who can sign in to the accept page" do
        # A real account has no raw token in hand, and /accept-invite is right
        # for them: they sign in and accept.
        expect(invitee.raw_invitation_token).to be_nil

        mail = described_class.team_invitation_email(invitee, inviter, team).deliver_now

        link = link_in(mail)
        expect(link).to include("/accept-invite/#{team.id}/#{invitee.uuid}")
        expect(link).not_to include("team_id=")
      end
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
        body = (mail.html_part || mail).body.decoded

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
        expect((mail.html_part || mail).body.decoded).to include("Hi there,")
      end
    end

    # #914. `role` had been a parameter of this method since it was written and
    # reached the template nowhere, so a Supervisor and a Support member
    # received byte-identical mail and neither was told what they could do.
    describe "the role the invitation was sent as" do
      def body_for(role)
        (described_class.team_invitation_email(invitee, inviter, team, role).deliver_now.html_part ||
          described_class.team_invitation_email(invitee, inviter, team, role).deliver_now).body.decoded
      end

      it "tells a supervisor they can edit shared boards but not the communicator" do
        body = body_for("supervisor")
        expect(body).to include("Supervisor")
        expect(body).to include("edit the ones shared with you")
        expect(body).to include("stay with the family")
      end

      it "tells a support member they cannot change anything" do
        body = body_for("member")
        expect(body).to include("Support")
        expect(body).to include("nothing changes unless the family changes it")
      end

      it "tells a read-only member they cannot break anything" do
        body = body_for("restricted")
        expect(body).to include("Read-Only")
      end

      it "produces different mail for different roles" do
        expect(body_for("supervisor")).not_to eq(body_for("member"))
      end

      it "falls back to the narrowest description for an unrecognized role" do
        expect(body_for("wizard")).to include("Support")
      end
    end

    # #914. The body named only the team, so a grandparent learned they had been
    # added to "a team" for "sharing boards" with no idea which child it was about.
    describe "naming the communicator" do
      it "names the communicator when the team has one" do
        owner = FactoryBot.create(:user, name: "Maya Ellison")
        account = FactoryBot.create(:child_account, user: owner, owner: owner, name: "Oliver")
        account_team = account.ensure_team!(creator: owner)

        mail = described_class.team_invitation_email(invitee, owner, account_team).deliver_now
        expect((mail.html_part || mail).body.decoded).to include("Oliver")
      end

      it "falls back to the team name when the team has no communicator" do
        mail = described_class.team_invitation_email(invitee, inviter, team).deliver_now
        expect((mail.html_part || mail).body.decoded).to include("Speech Crew")
      end
    end

    # #914. The template interpolated `@inviter.name` while the mailer computed
    # an unused `@inviter_name` fallback, so a blank name rendered
    # "You've been invited by  to join the team".
    describe "when the inviter has no name" do
      let(:inviter) { FactoryBot.create(:user, name: nil, email: "nameless@example.com") }

      it "falls back to the inviter's email rather than leaving a gap" do
        body = (described_class.team_invitation_email(invitee, inviter, team).deliver_now.html_part ||
          described_class.team_invitation_email(invitee, inviter, team).deliver_now).body.decoded

        expect(body).to include("nameless@example.com")
        expect(body).not_to match(/by\s{2,}added|by\s+added you/)
      end
    end
  end

  # #914. `API::TeamsController` contained no mailer at all, so after sending an
  # invite the owner had no signal ever — not when the person joined, not when
  # they didn't.
  describe "#team_member_joined_email" do
    let(:owner) { FactoryBot.create(:user, name: "Maya Ellison") }
    let(:member) { FactoryBot.create(:user, name: "Dana Whitfield") }
    let(:account) { FactoryBot.create(:child_account, user: owner, owner: owner, name: "Oliver") }
    let(:team) { account.ensure_team!(creator: owner) }

    before { team.upsert_member!(member, "supervisor") }

    def body_of(mail)
      (mail.html_part || mail).body.decoded
    end

    it "is addressed to the team's creator" do
      mail = described_class.team_member_joined_email(member, team).deliver_now

      expect(mail.to).to eq([owner.email])
      expect(mail.subject).to include("Dana Whitfield")
    end

    it "names the member, the communicator, and what the member can now do" do
      body = body_of(described_class.team_member_joined_email(member, team).deliver_now)

      expect(body).to include("Dana Whitfield")
      expect(body).to include("Oliver")
      expect(body).to include("Supervisor")
      expect(body).to include("/teams/#{team.id}")
    end

    it "reassures the owner they stay in control" do
      body = body_of(described_class.team_member_joined_email(member, team).deliver_now)
      expect(body).to include("remove them from the team")
    end

    it "describes a support member differently from a supervisor" do
      team.upsert_member!(member, "member")
      body = body_of(described_class.team_member_joined_email(member, team).deliver_now)

      expect(body).to include("Support")
      expect(body).not_to include("add boards of their own")
    end

    it "does not mail the owner about themselves" do
      mail = described_class.team_member_joined_email(owner, team)
      expect(mail.to).to be_nil
    end
  end
end
