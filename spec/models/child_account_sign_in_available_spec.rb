# frozen_string_literal: true

require "rails_helper"

# `sign_in_available?` is the public-page-safe answer to "is there a working
# private login behind this communicator's MySpeak page?" It ships on an
# unauthenticated payload, so it must be strictly narrower than `can_sign_in?`:
# a blank passcode would 401 at ChildAuthsController#create even when the plan
# rules say yes.
RSpec.describe ChildAccount, "#sign_in_available?", type: :model do
  let(:paid_user) { FactoryBot.create(:user, plan_type: "pro") }
  let(:free_user) { FactoryBot.create(:user) }

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

  it "is false for a Free (non-trial) owner" do
    account = FactoryBot.create(
      :child_account, user: free_user, owner: free_user,
      status: "active", passcode: "letmein1"
    )
    allow(account.user).to receive(:free_trial?).and_return(false)

    expect(account.sign_in_available?).to be(false)
  end
end
