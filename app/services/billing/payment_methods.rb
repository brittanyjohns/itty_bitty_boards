# frozen_string_literal: true

module Billing
  # Single lookup for "does Stripe have a chargeable payment method for this
  # customer?" — shared by the webhook's has_payment_method flag
  # (WebhooksController#payment_method_on_file?, the no-card reverse trial's
  # trial-banner CTA) and the plan-change immediate-charge guard
  # (SubscriptionsController#customer_has_payment_method?).
  #
  # Checks, in order: the subscription's own `default_payment_method` (no API
  # call needed), then the customer's `invoice_settings.default_payment_method`
  # (where the Customer Portal writes a new card), then the legacy Stripe
  # Sources API `default_source` field (older cards some customers still carry).
  #
  # Deliberately does NOT rescue Stripe errors — the two callers have
  # different, intentional fallback policies on a lookup failure and must keep
  # rescuing at their own call site:
  #   - SubscriptionsController#customer_has_payment_method? assumes "yes" on
  #     error, so an inconclusive lookup never blocks a plan change.
  #   - WebhooksController#payment_method_on_file? keeps the previously stored
  #     value on error, so a Stripe blip never flips the flag.
  # Collapsing those into one fallback here would break one of the two.
  module PaymentMethods
    module_function

    # `customer_id` may be a bare Stripe customer id string or an expanded
    # Stripe::Customer-like object (anything responding to `:id`).
    def on_file?(customer_id, subscription: nil)
      return true if subscription.respond_to?(:default_payment_method) && subscription.default_payment_method.present?

      raw_id = customer_id.respond_to?(:id) ? customer_id.id : customer_id
      return false if raw_id.blank?

      customer = Stripe::Customer.retrieve(raw_id)
      customer.invoice_settings&.default_payment_method.present? || customer.default_source.present?
    end
  end
end
