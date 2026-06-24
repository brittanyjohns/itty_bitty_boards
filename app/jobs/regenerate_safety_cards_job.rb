class RegenerateSafetyCardsJob < ApplicationJob
  queue_as :default

  # After a safety profile's slug changes (e.g. the random-slug migration),
  # its safety ID card + device tag carry a now-stale QR code. Regenerate both
  # from the current `public_url` and let the parent know fresh cards are ready.
  def perform(profile_id)
    profile = Profile.find_by(id: profile_id)
    return unless profile&.safety_profile?

    # regenerate: true forces a rebuild even if the freshness signature looks
    # unchanged — the slug (and thus the QR target) moved.
    Communicators::GenerateSafetyIdCard.call(profile, regenerate: true)
    Communicators::GenerateDeviceTag.call(profile, regenerate: true)

    child_account = profile.profileable
    return unless child_account.is_a?(ChildAccount)

    user = child_account.user
    return if user&.email.blank?

    CommunicationAccountMailer.safety_cards_updated(user, child_account).deliver_later
  end
end
