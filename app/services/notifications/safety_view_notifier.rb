# Delivers the "someone viewed your child's safety page" alert to a parent
# (issue #384).
#
# This is the channel-dispatch seam. v1 sends **email** via SafetyProfileMailer.
# A **push** channel is stubbed (`deliver_push`) so that when device-token
# registration + FCM/APNS land, push slots in here without touching the job,
# throttle, or opt-out logic. Until then it is a no-op log line.
#
# The caller (RecordProfileViewJob) owns throttling, opt-out, and the
# ProfileView audit record; this class only fans a single, already-vetted alert
# out to the enabled channels.
module Notifications
  class SafetyViewNotifier
    def self.deliver(profile:, profile_view:, owner:)
      new(profile: profile, profile_view: profile_view, owner: owner).deliver
    end

    def initialize(profile:, profile_view:, owner:)
      @profile = profile
      @profile_view = profile_view
      @owner = owner
    end

    def deliver
      deliver_email
      deliver_push # stub for now
      true
    end

    private

    attr_reader :profile, :profile_view, :owner

    def deliver_email
      return if owner&.email.blank?

      # deliver_later (not deliver_now) so a stalled SMTP session can't wedge the
      # worker thread — the app standardized on this after the #207 outage, and
      # the no-inline-mailer guard spec enforces it outside app/sidekiq/.
      SafetyProfileMailer.viewed_alert(profile, profile_view).deliver_later
    end

    # Push notifications are not wired up yet — there is no device-token
    # infrastructure in the app. When that exists, dispatch here. Kept as a
    # named seam so the channel fan-out is obvious and testable.
    def deliver_push
      return unless push_enabled?

      Rails.logger.info(
        "[SafetyViewNotifier] push channel not yet implemented " \
        "(profile=#{profile.id}, owner=#{owner&.id})"
      )
    end

    def push_enabled?
      # Future: owner.has_registered_devices? — false today, so this never fires.
      false
    end
  end
end
