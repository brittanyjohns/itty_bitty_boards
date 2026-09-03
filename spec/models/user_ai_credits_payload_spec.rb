require "rails_helper"

# `tokens` is the LEGACY per-image counter (User::WELCOME_TOKENS, spent by
# API::ImagesController#find_or_create) and was the only credit-shaped field on
# the user payload — so a client rendering an "AI credits" meter from the user
# object read 10 while every surface promised 25, and both numbers were right
# about their own quantity.
RSpec.describe User, "AI credit payload", type: :model do
  let(:user) { create(:user) }

  it "publishes the ledger balance and the allowance it is measured against" do
    view = user.api_view

    expect(view).to have_key(:ai_credits)
    expect(view).to have_key(:ai_credit_allowance)
    expect(view[:ai_credits]).to include(:plan, :topup, :total)
  end

  it "reports the Free plan's advertised allowance for a new Free account" do
    expect(user).to be_free
    expect(user.api_view[:ai_credit_allowance]).to eq(CreditService::PLAN_MONTHLY_CREDITS["free"])
    expect(user.api_view[:ai_credit_allowance]).to eq(25)
  end

  # The two numbers are different quantities and must both stay readable —
  # `tokens` is still spent by the image path, so it can't simply be dropped.
  it "keeps the legacy tokens field alongside them" do
    expect(user.api_view[:tokens]).to eq(user.tokens)
  end

  it "matches what GET /api/me/credits serves" do
    expect(user.api_view[:ai_credit_allowance]).to eq(CreditService.plan_allowance(user))
    expect(user.api_view[:ai_credits][:total]).to eq(CreditService.balance(user)[:total])
  end

  # plan_allowance reports the allowance actually GRANTED for the current
  # period, not the plan-type constant — that is what makes a Stripe Price
  # `monthly_credits` override show up in the gauge instead of the list price.
  it "reflects a grant that overrides the plan default" do
    CreditService.grant_plan!(user, amount: 999, period_end: 30.days.from_now, metadata: { source: "spec" })

    expect(user.reload.api_view[:ai_credit_allowance]).to eq(999)
  end
end
