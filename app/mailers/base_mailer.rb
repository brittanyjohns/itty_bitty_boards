class BaseMailer < ApplicationMailer
  def frontend_url
    ENV["FRONT_END_URL"] || "http://localhost:8100"
  end

  def team_invitation_email(invitee, inviter, team, role = "member")
    @invitee = invitee
    @inviter = inviter
    @team = team
    @invitee_name = @invitee.name
    @inviter_name = @inviter.email || @inviter.to_s
    @team_name = @team.name
    @user_name = @invitee.name
    @invitation_link = frontend_url
    if @invitee.raw_invitation_token.nil?
      @invitation_link += "/accept-invite/#{team.id}/#{@invitee.uuid}"
    else
      Rails.logger.info "User #{@invitee.id} already has a raw_invitation_token, using it for welcome link"
      token = @invitee.raw_invitation_token
      Rails.logger.info "User #{@invitee.id} has raw_invitation_token: #{token}"
      @invitation_link += "/invite/token/#{token}"
    end

    encoded_email = ERB::Util.url_encode(@invitee.email)
    @invitation_link += "?email=#{encoded_email}"

    subject = "You have been invited to join a team on SpeakAnyWay AAC!"
    mail(to: @invitee.email, subject: subject, from: "noreply@speakanyway.com")
    @invitee.update!(invitation_sent_at: Time.now)
  end
end
