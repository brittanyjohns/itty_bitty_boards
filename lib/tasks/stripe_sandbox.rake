# frozen_string_literal: true

# Seed a fresh Stripe Sandbox (or any test-mode Stripe account) with every
# Product, Price, and Promotion Code the app expects. Idempotent — safe to
# rerun; existing objects are skipped.
#
# Usage:
#   export STRIPE_API_KEY=sk_test_...   # from the target sandbox
#   bundle exec rake stripe:seed_sandbox
#
# Refuses to run against live-mode keys unless ALLOW_LIVE=true is set. The
# script never persists the key anywhere; it only reads it from ENV at
# request time (the `stripe` gem picks it up automatically).
namespace :stripe do
  desc "Create all Products, Prices, and the partner promo code in the current Stripe (test) account. Idempotent."
  task seed_sandbox: :environment do
    require "stripe"

    api_key = ENV["STRIPE_API_KEY"].to_s
    if api_key.empty?
      abort "[stripe:seed_sandbox] STRIPE_API_KEY is not set. Export the SANDBOX secret key (sk_test_...) and rerun."
    end

    unless api_key.start_with?("sk_test_") || ENV["ALLOW_LIVE"] == "true"
      abort "[stripe:seed_sandbox] STRIPE_API_KEY does not look like a test key (sk_test_...). Refusing to run. " \
            "Set ALLOW_LIVE=true to override (you almost certainly do not want to)."
    end

    Stripe.api_key = api_key

    # ---- Spec ---------------------------------------------------------------
    # currency is USD throughout. Prices are in cents.
    plans = [
      { product_name: "SpeakAnyWay MySpeak", env_var: "STRIPE_PRICE_MYSPEAK",
        unit_amount: 300, interval: "month",
        metadata: { plan_type: "myspeak", monthly_credits: "50" } },
      { product_name: "SpeakAnyWay MySpeak", env_var: "STRIPE_PRICE_MYSPEAK_YEAR",
        unit_amount: 3000, interval: "year",
        metadata: { plan_type: "myspeak", monthly_credits: "600" } },
      { product_name: "SpeakAnyWay Basic", env_var: "STRIPE_PRICE_BASIC",
        unit_amount: 800, interval: "month",
        metadata: { plan_type: "basic", monthly_credits: "400" } },
      { product_name: "SpeakAnyWay Basic", env_var: "STRIPE_PRICE_BASIC_YEAR",
        unit_amount: 8000, interval: "year",
        metadata: { plan_type: "basic", monthly_credits: "4800" } },
      { product_name: "SpeakAnyWay Pro", env_var: "STRIPE_PRICE_PRO",
        unit_amount: 2000, interval: "month",
        metadata: { plan_type: "pro", monthly_credits: "1500" } },
      { product_name: "SpeakAnyWay Pro", env_var: "STRIPE_PRICE_PRO_YEAR",
        unit_amount: 20000, interval: "year",
        metadata: { plan_type: "pro", monthly_credits: "18000" } },
      { product_name: "SpeakAnyWay Partner Pro", env_var: "STRIPE_PRICE_PARTNER_PRO",
        unit_amount: 2000, interval: "month",
        metadata: { plan_type: "partner_pro", monthly_credits: "1500" } },
    ]

    topups = [
      { product_name: "Credit Pack — Small", env_var: "STRIPE_PRICE_TOPUP_SMALL",
        unit_amount: 499,
        metadata: { kind: "topup", credit_amount: "100" } },
      { product_name: "Credit Pack — Medium", env_var: "STRIPE_PRICE_TOPUP_MEDIUM",
        unit_amount: 1999,
        metadata: { kind: "topup", credit_amount: "500" } },
      { product_name: "Credit Pack — Large", env_var: "STRIPE_PRICE_TOPUP_LARGE",
        unit_amount: 4999,
        metadata: { kind: "topup", credit_amount: "1500" } },
    ]

    promo_code = "PARTNERPILOT26"

    # ---- Helpers ------------------------------------------------------------
    products_by_name = {}

    find_or_create_product = lambda do |name|
      cached = products_by_name[name]
      return cached if cached

      existing = Stripe::Product.search(query: %(name:"#{name}" AND active:"true")).data.first
      product = existing || Stripe::Product.create(name: name)
      puts "#{existing ? '[skip]' : '[create]'} Product #{product.id} — #{name}"
      products_by_name[name] = product
      product
    rescue Stripe::StripeError => e
      warn "[error] Product '#{name}': #{e.class} — #{e.message}"
      nil
    end

    # Looks for an existing Price on a Product that matches all required
    # metadata keys AND the same recurrence shape. Recurrence comparison is
    # done in Ruby because Stripe's Price.search doesn't filter on
    # `recurring.interval` directly.
    find_matching_price = lambda do |product_id:, metadata:, interval: nil|
      meta_clauses = metadata.map { |k, v| %(metadata["#{k}"]:"#{v}") }
      query = ([%(product:"#{product_id}"), %(active:"true")] + meta_clauses).join(" AND ")
      Stripe::Price.search(query: query, limit: 10).data.find do |price|
        if interval
          price.recurring && price.recurring.interval == interval
        else
          price.type == "one_time"
        end
      end
    end

    results = {} # env_var => price_id

    seed_price = lambda do |entry, interval: nil|
      product = find_or_create_product.call(entry[:product_name])
      next unless product

      existing = find_matching_price.call(
        product_id: product.id,
        metadata: entry[:metadata],
        interval: interval,
      )

      price =
        if existing
          puts "[skip]   Price   #{existing.id} — #{entry[:env_var]} (#{entry[:product_name]} #{interval || 'one_time'})"
          existing
        else
          params = {
            product: product.id,
            currency: "usd",
            unit_amount: entry[:unit_amount],
            metadata: entry[:metadata],
          }
          params[:recurring] = { interval: interval } if interval
          created = Stripe::Price.create(params)
          puts "[create] Price   #{created.id} — #{entry[:env_var]} (#{entry[:product_name]} #{interval || 'one_time'})"
          created
        end

      results[entry[:env_var]] = price.id
    rescue Stripe::StripeError => e
      warn "[error] Price for #{entry[:env_var]}: #{e.class} — #{e.message}"
    end

    # ---- Run ---------------------------------------------------------------
    puts "Seeding Stripe (mode=#{api_key.start_with?('sk_test_') ? 'test' : 'LIVE'})..."

    plans.each   { |p| seed_price.call(p, interval: p[:interval]) }
    topups.each  { |t| seed_price.call(t) }

    # Partner pilot promo: 100% off, first 3 months. Create the underlying
    # Coupon first, then a Promotion Code pointing at it.
    begin
      existing_promo = Stripe::PromotionCode.list(code: promo_code, limit: 1).data.first
      if existing_promo
        puts "[skip]   Promo   #{existing_promo.id} — #{promo_code}"
      else
        coupon = Stripe::Coupon.create(
          name: "Partner Pilot — 3 months free",
          percent_off: 100,
          duration: "repeating",
          duration_in_months: 3,
          metadata: { purpose: "partner_pro_pilot_2026" },
        )
        created_promo = Stripe::PromotionCode.create(
          coupon: coupon.id,
          code: promo_code,
          active: true,
        )
        puts "[create] Promo   #{created_promo.id} — #{promo_code} (coupon=#{coupon.id})"
      end
    rescue Stripe::StripeError => e
      warn "[error] Promotion code #{promo_code}: #{e.class} — #{e.message}"
    end

    # ---- Output ------------------------------------------------------------
    puts
    puts "=== Paste into Hatchbox staging (Environment Variables) ==="
    %w[
      STRIPE_PRICE_MYSPEAK
      STRIPE_PRICE_MYSPEAK_YEAR
      STRIPE_PRICE_BASIC
      STRIPE_PRICE_BASIC_YEAR
      STRIPE_PRICE_PRO
      STRIPE_PRICE_PRO_YEAR
      STRIPE_PRICE_PARTNER_PRO
      STRIPE_PRICE_TOPUP_SMALL
      STRIPE_PRICE_TOPUP_MEDIUM
      STRIPE_PRICE_TOPUP_LARGE
    ].each do |key|
      val = results[key] || "<MISSING — see [error] above>"
      puts "#{key}=#{val}"
    end
    puts
    puts "Don't forget to also set on Hatchbox staging:"
    puts "  STRIPE_API_KEY=<this same sk_test_... key>"
    puts "  STRIPE_WEBHOOK_SECRET=<signing secret for the sandbox endpoint pointing at /api/webhooks>"
    puts
    puts "Done."
  end
end
