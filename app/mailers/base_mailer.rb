class BaseMailer < ApplicationMailer
  # Backend role -> the locale key describing what that person will be able to
  # do. Keyed on the stored role rather than the UI label so a label change is
  # a locale edit, and anything unrecognized falls back to the narrowest
  # description ("member" / Support) — over-promising access in an email is the
  # worse failure, and `TeamUser#set_defaults` already treats member as default.
  ROLE_DESCRIPTION_KEYS = {
    "admin" => "owner",
    "supervisor" => "supervisor",
    "member" => "member",
    "restricted" => "restricted",
  }.freeze

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
    # The template interpolates THIS, not `@inviter.name` — which is what it used
    # to do while this line quietly computed a fallback nothing read. An inviter
    # with a blank name rendered "You've been invited by  to join the team",
    # double space and all (#914).
    @inviter_name = @inviter.name.presence || @inviter.email.presence || "Someone"
    @team_name = @team.name
    @user_name = @invitee.name

    # What this invitation is actually ABOUT. The team name is usually
    # "<Name>'s Communication Team", but that is a label the owner can change,
    # and a grandparent reading "you've been added to a team for sharing boards"
    # has no idea which child it concerns. nil where a team has no communicator
    # yet, and the template drops the clause rather than printing an empty one.
    @communicator_name = @team.accounts.first&.name.presence

    # The recipient is told what they will be able to do. `role` has been a
    # parameter of this method since it was written and reached the template
    # nowhere, so a Supervisor and a Support member received byte-identical
    # mail — while the in-app invite panel goes to real trouble to explain the
    # difference to the SENDER (#914).
    @role_key = ROLE_DESCRIPTION_KEYS[role.to_s] || ROLE_DESCRIPTION_KEYS["member"]
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

  # Tell the team's creator that someone accepted. Nothing told them before —
  # `API::TeamsController` contained no mailer at all — so after sending an
  # invite the owner had no signal, ever: not when the person joined, not when
  # they didn't. Combined with the roster being unable to show an unaccepted
  # invite, the only way to find out whether a child's OT had access was to ask
  # the OT (#914).
  #
  # Addressed to the team's CREATOR rather than to whoever sent the invite:
  # `Team#can_invite` is `created_by_id` only, so they are the same person by
  # construction, and the creator is who the roster belongs to.
  def team_member_joined_email(member, team)
    @member = member
    @team = team
    @owner = team.created_by
    return if @owner.nil? || @owner.email.blank?
    return if @member.id == @owner.id

    @member_name = @member.name.presence || @member.email
    @team_name = @team.name
    @communicator_name = @team.accounts.first&.name.presence
    membership = TeamUser.find_by(user_id: @member.id, team_id: @team.id)
    @role_key = ROLE_DESCRIPTION_KEYS[membership&.role.to_s] || ROLE_DESCRIPTION_KEYS["member"]
    @team_link = "#{frontend_url}/teams/#{@team.id}"

    with_user_locale(@owner) do
      mail(
        to: @owner.email,
        subject: I18n.t("base_mailer.team_member_joined_email.subject", member_name: @member_name),
        from: "noreply@speakanyway.com",
      )
    end
  end
end
