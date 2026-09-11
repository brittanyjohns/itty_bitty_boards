class BaseMailer < ApplicationMailer
  def frontend_url
    ENV["FRONT_END_URL"] || "http://localhost:8100"
  end

  # Runs the block with I18n.locale set to the recipient's preferred locale.
  # Subjects, bodies, and any `t(...)` calls inside resolve against that
  # locale, falling back to :en (configured in application.rb).
  def with_user_locale(user, &block)
    locale = user.respond_to?(:i18n_locale) ? user.i18n_locale : :en
    I18n.with_locale(locale, &block)
  end

  def team_invitation_email(invitee, inviter, team, role = "member")
    @invitee = invitee
    @inviter = inviter
    @team = team
    @invitee_name = @invitee.name
    @inviter_name = @inviter.email || @inviter.to_s
    @team_name = @team.name
    @user_name = @invitee.name
    # Two link shapes, and which one an invitee gets decides whether the
    # invitation is usable at all (#915).
    #
    # `raw_invitation_token` is readable only on the instance that just minted
    # it, so its presence means "this account has never set a password and we
    # are holding a fresh token for it" — send them to the set-password page.
    # `User.invite_new_user_to_team!` is what guarantees a re-invite still
    # takes this branch; before it did, every invite after the first fell
    # through to `/accept-invite`, where a passwordless account can neither
    # sign up (`email_taken` — its own row holds the address) nor sign in
    # (there is no password).
    #
    # Absent, the invitee has a real account and `/accept-invite` is right:
    # they sign in and accept.
    @invitation_link = frontend_url
    encoded_email = ERB::Util.url_encode(@invitee.email)
    if @invitee.raw_invitation_token.nil?
      @invitation_link += "/accept-invite/#{team.id}/#{@invitee.uuid}"
      @invitation_link += "?email=#{encoded_email}"
    else
      @invitation_link += "/invite/token/#{@invitee.raw_invitation_token}"
      # `team_id` so the set-password page can say an invitation is waiting and
      # land the new member on the team. Without it the frontend falls back to
      # the plan dashboard, which never mentions the team they just joined —
      # correct, but it was the whole of what that page said.
      @invitation_link += "?email=#{encoded_email}&team_id=#{team.id}"
    end

    with_user_locale(@invitee) do
      mail(
        to: @invitee.email,
        subject: I18n.t("base_mailer.team_invitation_email.subject"),
        from: "noreply@speakanyway.com",
      )
    end
    @invitee.update!(invitation_sent_at: Time.now)
  end
end
