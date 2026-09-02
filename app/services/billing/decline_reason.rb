# frozen_string_literal: true

module Billing
  # Maps a Stripe PaymentIntent `last_payment_error` (`code` / `decline_code`)
  # onto the small, brand-safe vocabulary the past-due banner speaks. Pure
  # function, no Stripe calls.
  #
  # Two rules make this a mapping table rather than a pass-through:
  #
  # 1. It FAILS CLOSED. Anything unrecognized is "generic" — a reason we can't
  #    name is a reason whose CTA we can't get right, and "generic" tells the
  #    user to try a different payment method, which is never wrong.
  #
  # 2. The FRAUD BUCKET IS NEVER SURFACED. `lost_card`, `stolen_card`,
  #    `fraudulent` and friends map to "generic", per Stripe's own guidance:
  #    a real fraudster learns which of their cards is flagged, and — far more
  #    likely for us — these fire as false positives on legitimate customers,
  #    and telling a parent her card was reported stolen when it wasn't is a
  #    terrible experience. Mapping decline codes 1:1 is the easy mistake.
  #
  # Stripe's raw `message` never crosses this boundary either; the mapped
  # reason is the only thing the client is given.
  module DeclineReason
    GENERIC = "generic".freeze

    # Codes that earn their own reason, because each one implies a DIFFERENT
    # next action for the user.
    MAPPING = {
      # Wait and retry / use another card.
      "insufficient_funds" => "insufficient_funds",

      # Fixed in the billing portal by saving a new card.
      "expired_card" => "expired_card",

      # Fixed by re-entering the same card correctly.
      "incorrect_cvc" => "incorrect_details",
      "invalid_cvc" => "incorrect_details",
      "incorrect_number" => "incorrect_details",
      "invalid_number" => "incorrect_details",
      "invalid_expiry_month" => "incorrect_details",
      "invalid_expiry_year" => "incorrect_details",
      "incorrect_zip" => "incorrect_details",

      # The issuer refused a card that is otherwise fine. The billing portal
      # CANNOT fix these — re-saving the same card fails identically — so the
      # banner has to say "call your bank or use a different card".
      "generic_decline" => "bank_declined",
      "do_not_honor" => "bank_declined",
      "call_issuer" => "bank_declined",
      "transaction_not_allowed" => "bank_declined",
      "service_not_allowed" => "bank_declined",
      "card_not_supported" => "bank_declined",
      "currency_not_supported" => "bank_declined",
      "try_again_later" => "bank_declined",
      "processing_error" => "bank_declined",
      "issuer_not_available" => "bank_declined",
      "reenter_transaction" => "bank_declined",
      "revocation_of_authorization" => "bank_declined",
    }.freeze

    # Explicitly enumerated so the "never surface these" rule is testable and
    # can't be quietly lost by someone widening MAPPING.
    FRAUD_CODES = %w[
      lost_card
      stolen_card
      pickup_card
      fraudulent
      merchant_blacklist
      restricted_card
      security_violation
      stop_payment_order
    ].freeze

    # Folded into "generic" for v1. Its real CTA is completing a 3DS
    # confirmation at the invoice's `hosted_invoice_url` — a field we don't
    # store, and one the billing portal won't resolve — so surfacing the
    # reason without that link would send the user somewhere that can't fix
    # it. Off-session renewals with `payment_method_collection: if_required`
    # make it rare for us, and "try a different card" is not wrong. Give it a
    # row in MAPPING once we persist the invoice URL.
    DEFERRED_CODES = %w[authentication_required].freeze

    module_function

    # `decline_code` is the specific one when present (Stripe sets
    # `code: "card_declined"` and puts the detail in `decline_code`);
    # `code` carries the reason on its own for the validation-style failures.
    def for(code: nil, decline_code: nil)
      resolve(decline_code) || resolve(code) || GENERIC
    end

    def resolve(raw)
      key = raw.to_s.strip.downcase
      return nil if key.empty?
      return GENERIC if FRAUD_CODES.include?(key) || DEFERRED_CODES.include?(key)

      MAPPING[key]
    end
    private_class_method :resolve
  end
end
