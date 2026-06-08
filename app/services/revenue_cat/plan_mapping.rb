# frozen_string_literal: true

module RevenueCat
  # Single source of truth for mapping RevenueCat entitlements / store products
  # to our internal plan_type. The frontend keys entitlements as "basic"/"pro"
  # (see itty-bitty-frontend/src/services/iap.ts), so entitlement ids are the
  # primary signal; the store product id is a fallback.
  #
  # NOTE: PRODUCT_TO_PLAN keys must match the EXACT product identifiers that
  # App Store Connect / Google Play emit in webhook + REST payloads (usually
  # reverse-DNS, e.g. "com.speakanyway.basic.monthly"). The bare names below
  # mirror the RevenueCat *package* identifiers the app uses today; confirm
  # against a real sandbox webhook and adjust. resolve_plan_type logs when it
  # can't resolve so a wrong/missing key is loud, not silent.
  module PlanMapping
    ENTITLEMENT_TO_PLAN = {
      "basic" => "basic",
      "pro" => "pro",
    }.freeze

    PRODUCT_TO_PLAN = {
      "basic_monthly" => { plan_type: "basic", billing_interval: "monthly" },
      "basic_yearly" => { plan_type: "basic", billing_interval: "yearly" },
      "pro_monthly" => { plan_type: "pro", billing_interval: "monthly" },
      "pro_yearly" => { plan_type: "pro", billing_interval: "yearly" },
    }.freeze

    module_function

    def plan_type_for_entitlement(entitlement_id)
      ENTITLEMENT_TO_PLAN[entitlement_id.to_s]
    end

    def plan_type_for_product(product_id)
      PRODUCT_TO_PLAN.dig(product_id.to_s, :plan_type)
    end

    def billing_interval_for_product(product_id)
      PRODUCT_TO_PLAN.dig(product_id.to_s, :billing_interval)
    end

    # Resolve a normalized plan_type ("basic"/"pro" — never a *_yearly variant,
    # so it matches CreditService::PLAN_MONTHLY_CREDITS keys) from the
    # entitlement ids a purchase grants, falling back to the product id.
    # Returns nil (and logs) when nothing maps.
    def resolve_plan_type(entitlement_ids: [], product_id: nil)
      from_entitlement = Array(entitlement_ids).filter_map { |e| plan_type_for_entitlement(e) }.first
      resolved = from_entitlement || plan_type_for_product(product_id)

      if resolved.nil?
        Rails.logger.warn(
          "[RevenueCat::PlanMapping] could not resolve plan_type " \
          "(entitlements=#{Array(entitlement_ids).inspect} product_id=#{product_id.inspect})"
        )
      end

      resolved
    end
  end
end
