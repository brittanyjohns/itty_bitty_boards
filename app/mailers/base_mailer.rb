class BaseMailer < ApplicationMailer

    def team_invitation_email(invitee, inviter, team)
      puts "Sending team invitation email: params: #{params}"
      @invitee = invitee
      @inviter = inviter
      @team = team
      @invitee_name = @invitee.name
      @inviter_name = @inviter.name
      @team_name = @team.name
      @invitation_link = url_for(controller: 'teams', action: 'accept_invite', id: @team.id)
      subject = "You have been invited to join a team"
      mail(to: @invitee.email, subject: subject)
    end
  
end