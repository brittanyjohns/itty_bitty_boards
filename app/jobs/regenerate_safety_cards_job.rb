class RegenerateSafetyCardsJob < ApplicationJob
  queue_as :default

  # After a safety profile's slug changes (e.g. the random-slug migration), its
  # device tag carries a now-stale QR code. Rebuild it from the current
  # `public_url` and let the parent know a fresh tag is ready.
  #
  # This used to rebuild the Safety ID card alongside it. That card is no
  # longer offered on Print & share, so re-rendering it here would spend two
  # headless-Chrome renders refreshing a QR nobody is being handed. Anything
  # still holding a generated card (the internal API, an already-printed sheet)
  # keeps what it has; the endpoint can still rebuild one on request.
  def perform(profile_id)
    profile = Profile.find_by(id: profile_id)
    return unless profile&.safety_profile?

    # regenerate: true forces a rebuild even if the freshness signature looks
    # unchanged — the slug (and thus the QR target) moved.
    Communicators::GenerateDeviceTag.call(profile, regenerate: true)

    child_account = profile.profileable
    return unless child_account.is_a?(ChildAccount)

    user = child_account.user
    return if user&.email.blank?

    CommunicationAccountMailer.safety_cards_updated(user, child_account).deliver_later
  end
end
