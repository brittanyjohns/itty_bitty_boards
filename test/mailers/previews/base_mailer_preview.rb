# Preview all emails at http://localhost:4000/rails/mailers/base_mailer
class BaseMailerPreview < ActionMailer::Preview
  def team_invitation
    team = Team.last
    puts "Team: #{team.inspect}"
    inviter = team.created_by
    invitee = User.admin.first
    result = BaseMailer.team_invitation_email(invitee, inviter, team).deliver_now
  end

  def invite_new_user_to_team
    team = Team.last
    puts "Team: #{team.inspect}"
    inviter = team.created_by
    email = "bhannajohns+tesssssssstteamusertest2q@gmail.com"

    result = BaseMailer.invite_new_user_to_team_email(email, inviter, team).deliver_now
  end
end
