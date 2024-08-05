class BaseMailer < ApplicationMailer
  def team_invitation_email(invitee, inviter, team)
    raise "Missing required parameters" unless invitee && inviter && team
    puts "Sending team invitation email: #{invitee.email} - #{inviter.email} - #{team.name}"
    if invitee.raw_invitation_token
      puts "Invitee already has a token: #{invitee.raw_invitation_token}"
      @invitation_link = accept_team_invitation_url(invitation_token: invitee.raw_invitation_token, team_id: team.id)
    else
      puts "Invitee does not have a token"
      # @invitation_link = url_for(controller: 'teams', action: 'accept_invite', id: team.id, email: invitee.email)
      frontend_url = Rails.env.production? ? "https://www.speakanyway.com" : "http://localhost:8100"
      Rails.logger.info "Frontend URL: #{frontend_url}"
      @invitation_link = frontend_url + "/accept_invite?team_id=#{team.id}&email=#{invitee.email}"
    end
    puts "Invitation link: #{@invitation_link}"
    @invitee = invitee
    @inviter = inviter
    @team = team
    @invitee_name = @invitee.name
    @inviter_name = @inviter.email || @inviter.to_s
    @team_name = @team.name

    subject = "You have been invited to join a team"
    mail_result = mail(to: @invitee.email, subject: subject)
    puts "Mail result: #{mail_result.inspect}"
    mail_result
  end
end
