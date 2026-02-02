module StripeHelper
  def create_stripe_customer(user)
    Stripe::Customer.create(
      email: user.email,
      name: user.name,
      metadata: { user_id: user.id },
    )
  end

  def delete_stripe_customer(stripe_customer_id)
    Stripe::Customer.delete(stripe_customer_id)
  end

  SOFT_DELETE_EMAIL_DOMAIN = "deleted.speakanyway.local".freeze

  class AccountDeletionError < StandardError; end

  # Public: Soft delete the account in a safe, auditable way.
  #
  # What it does:
  # - Cancels Stripe subscription (immediate by default)
  # - Optionally detaches payment methods
  # - Marks plan as canceled + expires now
  # - Revokes auth tokens (jti/authentication_token/temp_login_token)
  # - Anonymizes PII (email, name, etc)
  # - Locks the account + sets a tombstone in settings
  #
  # Usage:
  #   user.soft_delete_stripe_customer!(reason: "user_requested", actor_id: current_user.id)
  #
  def soft_delete_stripe_customer!(
    reason: "user_requested",
    actor_id: nil,
    cancel_immediately: true,
    detach_payment_methods: true,
    delete_stripe_customer: false # strongly recommend false
    
  )
    raise AccountDeletionError, "User already deleted" if soft_deleted?

    now = Time.current

    transaction do
      # 1) Stripe cleanup first (so we don't lose IDs/PII before calling Stripe)
      begin
        cancel_stripe_subscription!(cancel_immediately: cancel_immediately)
        detach_stripe_payment_methods! if detach_payment_methods
        mark_stripe_customer_deleted_metadata!(reason: reason, actor_id: actor_id, deleted_at: now)
        delete_stripe_customer! if delete_stripe_customer
      rescue => e
        # If you want to allow deletion even if Stripe fails, remove this raise
        raise AccountDeletionError, "Stripe cleanup failed: #{e.class} #{e.message}"
      end

      # 2) App-side access shutdown
      revoke_all_sessions_and_tokens!

      # 3) Anonymize / tombstone
      anonymize_personal_data_and_delete_all_data!(deleted_at: now, reason: reason, actor_id: actor_id)

      # 4) Plan state (optional but helpful for UI/admin)
      self.plan_status = "deleted"
      self.plan_expires_at = now
      self.plan_type = "free"
      self.paid_plan_type = nil

      # Prevent login / future use
      self.locked = true

      save!
    end

    true
  end

  def soft_deleted?
    deleted_at.present?
  end

  private

  # --- Stripe helpers ---

  def cancel_stripe_subscription!(cancel_immediately:)
    return if stripe_subscription_id.blank?
    sub = Stripe::Subscription.retrieve(stripe_subscription_id)

    if cancel_immediately
      # Ends now; user loses access now (your app should enforce plan_status/locked anyway)
      Stripe::Subscription.cancel(sub.id)
    else
      # Ends at period end
      Stripe::Subscription.update(sub.id, cancel_at_period_end: true)
    end
  rescue Stripe::InvalidRequestError => e
    # If the subscription doesn't exist anymore, swallow it
    raise unless e.message.to_s.downcase.include?("no such subscription")
  end

  def detach_stripe_payment_methods!
    return if stripe_customer_id.blank?
    # Detach card-type PaymentMethods (common)
    pms = Stripe::PaymentMethod.list(customer: stripe_customer_id, type: "card")
    pms.data.each do |pm|
      Stripe::PaymentMethod.detach(pm.id)
    end
  rescue Stripe::InvalidRequestError => e
    # If customer doesn't exist, ignore
    raise unless e.message.to_s.downcase.include?("no such customer")
  end

  def mark_stripe_customer_deleted_metadata!(reason:, actor_id:, deleted_at:)
    return if stripe_customer_id.blank?

    Stripe::Customer.update(
      stripe_customer_id,
      metadata: {
        "speakanyway_deleted" => "true",
        "speakanyway_deleted_reason" => reason.to_s,
        "speakanyway_deleted_actor_id" => actor_id.to_s,
        "speakanyway_deleted_at" => deleted_at.iso8601,
      },
    )
  rescue Stripe::InvalidRequestError => e
    raise unless e.message.to_s.downcase.include?("no such customer")
  end

  def delete_stripe_customer!
    return if stripe_customer_id.blank?

    Stripe::Customer.delete(stripe_customer_id)
  rescue Stripe::InvalidRequestError => e
    raise unless e.message.to_s.downcase.include?("no such customer")
  end

  # --- App-side helpers ---

end
