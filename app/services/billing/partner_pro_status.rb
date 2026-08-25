# frozen_string_literal: true

module Billing
  # Read-only view of what Stripe actually believes about a user's subscription,
  # for the admin user page.
  #
  # This exists because the local record stores no price id at all — only
  # `plan_type` and `stripe_subscription_id`. The failure mode the Partner Pro
  # upgrade guards against is precisely "our row says partner_pro while the
  # Stripe subscription is still on the basic price", and a locally-rendered
  # card structurally cannot answer that. So the snapshot goes to Stripe.
  #
  # Never raises: a Stripe outage renders an "unavailable" line on the admin
  # page instead of 500ing it (external-service failures fail soft).
  #
  # Deliberately NOT cached — a cache would show the admin stale state right
  # after they performed a swap, which is the one moment they're looking.
  module PartnerProStatus
    module_function

    # The subscription item carrying the PLAN price.
    #
    # The single copy of this rule: both the webhook's read path
    # (Api::WebhooksController#first_price_from_subscription) and the Partner
    # Pro write path (User#swap_primary_item_to!) resolve the plan item through
    # here, so a subscription can never be read as one plan and written as
    # another.
    #
    # Stripe does not guarantee item order, so `items.data.first` is wrong: a
    # Pro user who bought extra-communicator slots has two items and the add-on
    # can come first. Prefer the item whose Price carries plan_type metadata,
    # then any non-add-on item, then fall back to the first item.
    def plan_item(subscription)
      items = subscription&.items&.data || []
      return nil if items.empty?

      plan = items.find do |item|
        meta = item.price&.metadata || {}
        meta["plan_type"].present? && !Billing::ExtraCommunicators.extra_comm_item?(item)
      end
      plan ||= items.find { |item| !Billing::ExtraCommunicators.extra_comm_item?(item) }
      plan || items.first
    end

    def partner_price_id
      ENV.fetch("STRIPE_PRICE_PARTNER_PRO", nil).presence
    end

    # Snapshot of the user's live Stripe subscription. Always a Hash; keys other
    # than :subscription_id may be nil when Stripe couldn't be reached.
    def snapshot(user)
      sub_id = user&.stripe_subscription_id
      return { subscription_id: nil } if sub_id.blank?

      subscription = Stripe::Subscription.retrieve(sub_id)
      item = plan_item(subscription)
      price = item&.price
      price_id = price&.id

      {
        subscription_id: sub_id,
        status: subscription.status,
        price_id: price_id,
        price_plan_type: (price&.metadata || {})["plan_type"],
        interval: interval_for(price),
        amount: amount_for(price),
        on_partner_price: partner_price_id.present? && price_id == partner_price_id,
        trial_end: timestamp_or_nil(subscription.try(:trial_end)),
        cancel_at_period_end: subscription.try(:cancel_at_period_end) || false,
        error: nil,
      }
    rescue Stripe::InvalidRequestError => e
      return { subscription_id: sub_id, error: "Not found in Stripe" } if e.code.to_s == "resource_missing"

      { subscription_id: sub_id, error: "Stripe error: #{e.class}" }
    rescue => e
      Rails.logger.error "[PartnerProStatus] snapshot failed for user=#{user&.id}: #{e.class} - #{e.message}"
      { subscription_id: sub_id, error: "Stripe unavailable: #{e.class}" }
    end

    # "monthly" / "yearly" / the raw Stripe interval, or nil for a one-off price.
    def interval_for(price)
      recurring = price.respond_to?(:recurring) ? price.recurring : nil
      return nil if recurring.nil?

      interval = recurring.respond_to?(:interval) ? recurring.interval : recurring["interval"]
      case interval
      when "month" then "monthly"
      when "year" then "yearly"
      else interval
      end
    end

    # Formatted price amount ("$10.00"), or nil when Stripe reports none (e.g.
    # tiered pricing, where unit_amount is null).
    def amount_for(price)
      cents = price.respond_to?(:unit_amount) ? price.unit_amount : nil
      return nil if cents.nil?

      format("$%.2f", cents.to_i / 100.0)
    end

    def timestamp_or_nil(raw)
      return nil if raw.blank?

      raw.is_a?(Integer) ? Time.at(raw) : raw
    end
  end
end
