# frozen_string_literal: true

module Analytics
  # Server-side PostHog events for the communicator + page funnel (#766).
  #
  # Everything here is captured server-side on purpose. The frontend SDK is
  # consent-gated (`opt_out_capturing_by_default`, `person_profiles:
  # "identified_only"` — #312), so a user who never accepts the cookie banner
  # produces no frontend events at all. That is exactly the user who then emails
  # support about a limit they hit, so a server-side capture is the only floor we
  # can rely on: it survives a non-consenting user, an ad blocker, and a JS
  # error.
  #
  # Event names are snake_case. The legacy spaced `communicator account created`
  # fired by the frontend's ChildAccountForm is being retired in
  # itty-bitty-frontend#750; the two names are distinct in PostHog, so they can't
  # double-count against each other while both exist.
  #
  # `source` says which creation route ran, because that is the coverage gap
  # that motivated this: the MySpeak wizard creates its communicator entirely
  # server-side and never touches the form component the old event lived in, so
  # onboarding-created communicators were silently uncounted.
  #
  # Every capture routes through PosthogService, which rescues — analytics can
  # never break a create.
  module CommunicatorEvents
    extend self

    CHILD_ACCOUNTS = "child_accounts"
    MYSPEAK_ONBOARDING = "myspeak_onboarding"

    # A user was refused a communicator by Permissions::CommunicatorLimits.
    # This is the hard stop at the end of a multi-step wizard that was, before
    # #766, captured nowhere at all.
    def slot_limit_reached(user:, status:, source:)
      return unless user

      usage = Permissions::CommunicatorLimits.usage_for(user: user, status: status)

      PosthogService.capture_for_user(
        user,
        "communicator_slot_limit_reached",
        properties: {
          status: status,
          limit: usage[:limit],
          count: usage[:count],
          source: source,
        },
      )
    end

    def account_created(user:, child:, source:)
      return unless user && child

      PosthogService.capture_for_user(
        user,
        "communicator_account_created",
        properties: {
          status: child.status,
          communicator_id: child.id,
          source: source,
        },
      )
    end

    # Every communicator auto-mints exactly one Profile (its MySpeak page) at
    # create time. That side effect used to leave no trace anywhere, which is
    # what made a MySpeak-page question unanswerable from the data.
    def myspeak_page_created(user:, profile:, child:, source:)
      return unless user && profile

      PosthogService.capture_for_user(
        user,
        "myspeak_page_created",
        properties: {
          profile_id: profile.id,
          communicator_id: child&.id,
          source: source,
        },
      )
    end

    # The wizard set up a page on a communicator that already existed, instead
    # of creating a new one, because the user had no slot left. A distinct
    # event rather than a flag on `myspeak_page_created`: no communicator was
    # created here, so this must never land in the same count as a create.
    # Pairs with `communicator_slot_limit_reached` — every adopt is a refusal
    # that used to be a dead end.
    def myspeak_page_adopted(user:, profile:, child:, source:)
      return unless user && profile

      PosthogService.capture_for_user(
        user,
        "myspeak_page_adopted",
        properties: {
          profile_id: profile.id,
          communicator_id: child&.id,
          source: source,
        },
      )
    end

    # The user-level Public page (User has_one :profile) — a different product
    # from a communicator's MySpeak page, with a different quota.
    def public_page_created(user:, profile:)
      return unless user && profile

      PosthogService.capture_for_user(
        user,
        "public_page_created",
        properties: { profile_id: profile.id },
      )
    end

    # The 409 a second Public page gets. A state conflict rather than a plan
    # gate, but just as invisible before this.
    def public_page_create_blocked(user:, reason:)
      return unless user

      PosthogService.capture_for_user(
        user,
        "public_page_create_blocked",
        properties: { reason: reason },
      )
    end
  end
end
