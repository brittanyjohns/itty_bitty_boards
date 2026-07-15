# frozen_string_literal: true

module Billing
  # Pro-only "extra communicator" add-on slots. A user's total communicator slot
  # limit is their plan's base limit PLUS settings["extra_communicator_slots"]
  # (see Permissions::CommunicatorLimits.slot_limit_for). Buying extras is the
  # thing that finally makes purchased slots creatable — the settings key is read
  # by the single creation gate.
  #
  # Three purchase paths, all funnelling into settings["extra_communicator_slots"]:
  #   - monthly / yearly — a recurring Stripe subscription item on the Pro
  #     subscription (quantity = number of extras). The subscription webhook
  #     re-derives the count from the live subscription items, so add / remove /
  #     cancel self-heals (POST /api/subscriptions/communicator_addon drives it).
  #   - license (one-time) — bundled with a pro_5yr 5-Year license purchase; the
  #     count rides the checkout metadata and is granted by the license webhook.
  #     It expires with the license (PlanExpiryJob -> apply_free_plan clears it).
  #
  # Slots are Pro-only: a non-Pro plan always resolves to 0 extras (the webhook
  # and endpoint both gate on User#pro?).
  module ExtraCommunicators
    module_function

    # The single settings key every path writes and slot_limit_for reads.
    SETTINGS_KEY = "extra_communicator_slots"

    # kind => ENV var holding the Stripe Price id. Resolved at call time (not a
    # frozen constant value) so deploy/test ENV changes take effect without a
    # class-cache reset — same pattern as the license/top-up price keys.
    PRICE_ENV_KEYS = {
      "monthly" => "STRIPE_PRICE_PRO_EXTRA_COMM_MONTHLY",
      "yearly" => "STRIPE_PRICE_PRO_EXTRA_COMM_YEARLY",
      "license" => "STRIPE_PRICE_PRO_EXTRA_COMM_5YR",
    }.freeze

    # Max extra slots a single account can buy — guards runaway quantity input.
    def max
      ENV.fetch("MAX_EXTRA_COMMUNICATORS", 20).to_i
    end

    def clamp(count)
      count.to_i.clamp(0, max)
    end

    # Stripe Price id for a purchase kind ("monthly"|"yearly"|"license"), or nil
    # when that price is unconfigured in this environment.
    def price_id(kind)
      env_key = PRICE_ENV_KEYS[kind.to_s]
      env_key && ENV[env_key].presence
    end

    # The recurring add-on price for a billing interval. Anything other than
    # "yearly" falls back to the monthly price.
    def recurring_price_id(interval)
      price_id(interval.to_s == "yearly" ? "yearly" : "monthly")
    end

    # Every configured add-on price id (recurring + license), for matching a
    # Stripe line/subscription item back to "this is an extra-communicator charge".
    def price_ids
      PRICE_ENV_KEYS.keys.map { |k| price_id(k) }.compact
    end

    # A Stripe line/subscription item is an extra-comm charge when its price id is
    # one we configured OR its price metadata is tagged `kind=extra_communicator`.
    # The metadata tag keeps matching robust even if a price id is rotated.
    def extra_comm_item?(item)
      price = item.respond_to?(:price) ? item.price : item["price"]
      return false unless price

      id = price.respond_to?(:id) ? price.id : price["id"]
      return true if price_ids.include?(id)

      meta = price.respond_to?(:metadata) ? price.metadata : price["metadata"]
      return false unless meta

      tag = meta.respond_to?(:[]) ? (meta["kind"] || meta[:kind]) : nil
      tag.to_s == "extra_communicator"
    end

    # Total extra-comm quantity across a Stripe subscription's items (0 if none).
    def quantity_from_subscription(subscription)
      items = subscription&.items&.data || []
      items.sum do |item|
        next 0 unless extra_comm_item?(item)

        qty = item.respond_to?(:quantity) ? item.quantity : item["quantity"]
        qty.to_i
      end
    end
  end
end
