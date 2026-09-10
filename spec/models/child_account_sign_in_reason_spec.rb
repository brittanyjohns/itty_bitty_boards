# frozen_string_literal: true

require "rails_helper"

# `ChildAuthsController#create` answers every failure with the same generic
# "invalid credentials", and it has to: a login endpoint that explained itself
# would confirm whether a username exists to anyone who asked. The cost is that
# a communicator who CANNOT sign in — no passcode, archived, over the slot limit
# — is indistinguishable from a typo, from the outside and from the logs.
#
# 21 days of production logs contain no successful communicator sign-in by any
# real user, and a read-only query found 5 non-sandbox, unarchived communicators
# with a blank passcode: real accounts, holding real slots, that had never been
# able to sign in and never would. Nothing anywhere said so.
#
# The owner is already authenticated and already sees the passcode, so they are
# the one party who can safely be told. That is what `sign_in_unavailable_reason`
# is for.
RSpec.describe "ChildAccount#sign_in_unavailable_reason" do
  let(:owner) { create(:user) }

  def communicator(**attrs)
    create(:child_account, user: owner, owner: owner, **attrs)
  end

  # The invariant that makes the reason trustworthy: it is derived FROM
  # sign_in_available?, never re-derived alongside it, so the two cannot drift.
  # The pattern `communicator_slots` established — one answer, not two copies.
  describe "agreement with sign_in_available?" do
    it "gives a reason exactly when sign-in is unavailable" do
      cases = [
        communicator(status: ChildAccount::SANDBOX),
        communicator(status: ChildAccount::ACTIVE, passcode: nil),
        communicator(status: ChildAccount::ACTIVE, passcode: ""),
        communicator(status: ChildAccount::ACTIVE, passcode: "secret12"),
        communicator(status: ChildAccount::LOANER, passcode: "secret12"),
      ]

      cases.each do |account|
        if account.sign_in_available?
          expect(account.sign_in_unavailable_reason).to be_nil,
            "#{account.username} can sign in but gave a reason"
        else
          expect(account.sign_in_unavailable_reason).to be_present,
            "#{account.username} cannot sign in but gave no reason"
        end
      end
    end
  end

  it "is nil for a communicator whose login works" do
    account = communicator(status: ChildAccount::ACTIVE, passcode: "secret12")

    expect(account.sign_in_available?).to be(true)
    expect(account.sign_in_unavailable_reason).to be_nil
  end

  # The 5 rows found in production.
  it "names a blank passcode on a non-sandbox account" do
    account = communicator(status: ChildAccount::ACTIVE, passcode: nil)

    expect(account.sign_in_unavailable_reason).to eq("no_passcode")
  end

  it "treats an empty-string passcode the same as a nil one" do
    account = communicator(status: ChildAccount::ACTIVE, passcode: "")

    expect(account.sign_in_unavailable_reason).to eq("no_passcode")
  end

  it "names a sandbox, which has no login by design" do
    account = communicator(status: ChildAccount::SANDBOX)

    expect(account.sign_in_unavailable_reason).to eq("sandbox")
  end

  # Archived is the nastiest of the set: the row can hold a perfectly valid
  # passcode, but `default_scope` hides it from `valid_credentials?`, so the
  # correct credentials come back as "invalid".
  it "names an archived communicator even when its passcode is still valid" do
    account = communicator(status: ChildAccount::ACTIVE, passcode: "secret12")
    account.update!(archived_at: Time.current)

    expect(ChildAccount.find_by(username: account.username)).to be_nil
    expect(account.sign_in_unavailable_reason).to eq("archived")
  end

  it "names fallback mode" do
    account = communicator(status: ChildAccount::ACTIVE, passcode: "secret12")
    account.enter_fallback!

    expect(account.sign_in_unavailable_reason).to eq("fallback_mode")
  end
end

RSpec.describe "ChildAccount#api_view sign-in diagnostics" do
  let(:owner) { create(:user) }
  let(:other) { create(:user) }

  let(:account) do
    create(:child_account, user: owner, owner: owner,
                           status: ChildAccount::ACTIVE, passcode: nil)
  end

  it "tells the owner why the login does not work" do
    view = account.api_view(owner)

    expect(view[:sign_in_available]).to be(false)
    expect(view[:sign_in_unavailable_reason]).to eq("no_passcode")
  end

  # Same gate #903 put on the passcode itself: the reason describes the login,
  # so a non-owner reader does not get it.
  it "withholds the reason from a viewer who cannot see the passcode" do
    view = account.api_view(other)

    expect(view[:passcode]).to be_nil
    expect(view[:sign_in_unavailable_reason]).to be_nil
  end

  it "keeps the key present so the payload shape is stable" do
    expect(account.api_view(other)).to have_key(:sign_in_unavailable_reason)
  end

  it "reports nil reason on a working account" do
    working = create(:child_account, user: owner, owner: owner,
                                     status: ChildAccount::ACTIVE, passcode: "secret12")

    view = working.api_view(owner)
    expect(view[:sign_in_available]).to be(true)
    expect(view[:sign_in_unavailable_reason]).to be_nil
  end
end
