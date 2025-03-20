class BaseMailer < ApplicationMailer
  def team_invitation_email(invitee_email, inviter, team)
    unless invitee_email && inviter && team
      puts "Missing required parameters: invitee_email: #{invitee_email}, inviter: #{inviter}, team: #{team}"
      raise "Missing required parameters"
    end
    attempt = 0
    while attempt < 3
      begin
        invitee = User.find_by(email: invitee_email)
        break if invitee
        sleep 2
      rescue StandardError => e
        puts "Error finding invitee: #{e.inspect}"
      ensure
        attempt += 1
      end
    end
    unless invitee
      puts "Invitee not found: #{invitee_email}"
      raise "Invitee not found"
    end
    team.add_member!(invitee, "member")
    # if invitee.raw_invitation_token
    #   @invitation_link = accept_team_invitation_url(invitation_token: invitee.raw_invitation_token, team_id: team.id)
    # else
    # @invitation_link = url_for(controller: 'teams', action: 'accept_invite', id: team.id, email: invitee.email)
    frontend_url = Rails.env.production? ? "https://speakanyway.com" : "http://localhost:8100"
    @invitation_link = frontend_url + "/accept-invite/#{team.id}/#{invitee.uuid}"
    # end
    @invitee = invitee
    @inviter = inviter
    @team = team
    @invitee_name = @invitee.name
    @inviter_name = @inviter.email || @inviter.to_s
    @team_name = @team.name

    subject = "You have been invited to join a team on SpeakAnyWay AAC!"
    mail(to: @invitee.email, subject: subject, from: "hello@speakanyway.com")
    invitee.update!(invitation_sent_at: Time.now)
    invitee
  end

  def invite_new_user_to_team_email(email, inviter, team)
    puts "Inviting new user to team: #{email}, #{inviter}, #{team}"
    unless email && inviter && team
      puts "Missing required parameters: email: #{email}, inviter: #{inviter}, team: #{team}"
      raise "Missing required parameters"
    end

    temp_passowrd = Devise.friendly_token.first(12)
    user = User.new(email: email, password: temp_passowrd)
    if user.save
      puts "User created: #{user.inspect}"
    else
      puts "User not created: #{user.errors.full_messages}"
    end

    # @invitation_link = url_for(controller: 'teams', action: 'accept_invite', id: team.id, email: invitee.email)
    frontend_url = Rails.env.production? ? "https://speakanyway.com" : "http://localhost:8100"
    @invitation_link = frontend_url + "/accept-new-invite/#{team.id}/#{temp_passowrd}"
    @invitee = user
    @inviter = inviter
    @team = team
    @invitee_name = @invitee.name
    @inviter_name = @inviter.email || @inviter.to_s
    @team_name = @team.name

    subject = "You have been invited to join a team on SpeakAnyWay AAC!"
    mail_result = mail(to: @invitee.email, subject: subject)
    mail_result
  end
end
