# frozen_string_literal: true

require "rails_helper"

# `sign_in_available?` is the public-page-safe answer to "is there a working
# private login behind this communicator's MySpeak page?" It ships on an
# unauthenticated payload, so it must be strictly narrower than `can_sign_in?`:
# a blank passcode would 401 at ChildAuthsController#create even when the plan
# rules say yes.
RSpec.describe ChildAccount, "#sign_in_available?", type: :model do
  let(:paid_user) { FactoryBot.create(:user, plan_type: "pro") }
  # :free_user is backdated a year, so it is well past the 14-day
  # `User#free_trial?` window — no stubbing needed to assert the real state.
  let(:free_user) { FactoryBot.create(:free_user) }

  it "is true for an active communicator with a passcode on a paid plan" do
    account = FactoryBot.create(
      :child_account, user: paid_user, owner: paid_user,
      status: "active", passcode: "letmein1"
    )

    expect(account.sign_in_available?).to be(true)
  end

  it "is false for a sandbox communicator" do
    account = FactoryBot.create(
      :child_account, user: paid_user, owner: paid_user,
      status: "sandbox", passcode: "letmein1"
    )

    expect(account.sign_in_available?).to be(false)
  end

  it "is false when the passcode is blank, even though can_sign_in? says yes" do
    account = FactoryBot.create(
      :child_account, user: paid_user, owner: paid_user,
      status: "active", passcode: nil
    )

    expect(account.can_sign_in?).to be(true)
    expect(account.sign_in_available?).to be(false)
  end

  it "is false for a communicator in fallback mode" do
    account = FactoryBot.create(
      :child_account, user: paid_user, owner: paid_user,
      status: "active", passcode: "letmein1"
    )
    account.enter_fallback!

    expect(account.reload.sign_in_available?).to be(false)
  end

  it "is false for an archived communicator" do
    account = FactoryBot.create(
      :child_account, user: paid_user, owner: paid_user,
      status: "active", passcode: "letmein1"
    )
    account.update!(archived_at: Time.current)

    expect(account.sign_in_available?).to be(false)
  end

  # #876. This used to assert the opposite. `can_sign_in?` fell through to
  # `user.free_trial?` for a non-paid owner — the 14-day-from-signup window,
  # not a subscription — so a claimed communicator on a Free account lost its
  # passcode login on day 15 of the PARENT's signup. marketing/pricing-structure.md
  # prices the other way: "Free hosts 1 claimed communicator ... (real login)
  # so the hand-off never hits a paywall."
  it "is true for an active communicator on a Free owner, however old the account" do
    account = FactoryBot.create(
      :child_account, user: free_user, owner: free_user,
      status: "active", passcode: "letmein1"
    )

    expect(free_user).to be_free
    expect(free_user.free_trial?).to be(false)
    expect(account.can_sign_in?).to be(true)
    expect(account.sign_in_available?).to be(true)
  end

  # The gates that DO apply on Free, so the example above can't be read as
  # "Free communicators always sign in".
  it "is false for a sandbox communicator on a Free owner" do
    account = FactoryBot.create(
      :child_account, user: free_user, owner: free_user,
      status: "sandbox", passcode: "letmein1"
    )

    expect(account.can_sign_in?).to be(false)
    expect(account.sign_in_available?).to be(false)
  end

  it "is false for a Free owner's communicator in fallback mode after a downgrade" do
    account = FactoryBot.create(
      :child_account, user: free_user, owner: free_user,
      status: "active", passcode: "letmein1"
    )
    account.enter_fallback!

    expect(account.reload.can_sign_in?).to be(false)
    expect(account.sign_in_available?).to be(false)
  end
end
