# frozen_string_literal: true

require "rails_helper"

# Guardrail for a name collision that reads like a data bug.
#
# `ChildAccount#is_demo` is a legacy alias for `sandbox?` — a plan-driven
# LIFECYCLE status. `Permissions::CommunicatorLimits.self_create_status` forces
# every Free user's self-created communicator to sandbox (Free's one full slot
# is reserved for a claim/hand-off), so a genuine Free parent's communicator
# reads `is_demo: true`. That is correct and deliberate.
#
# The test/internal predicate — what the Mailchimp DEMO_USER merge field, the
# journey gate, `User.demo_accounts` and Mission Control's `without_demo` all
# read — is `User#demo_user?`, one level up on the USER. A filter keyed on the
# communicator's `is_demo` instead would silently drop every real Free user,
# which is exactly the cohort those exclusions exist to preserve.
RSpec.describe "ChildAccount#is_demo vs User#demo_user?" do
  let(:free_user) { create(:free_user) }

  let(:communicator) do
    status = Permissions::CommunicatorLimits.self_create_status(
      user: free_user,
      requested: ChildAccount::ACTIVE,
    )
    create(:child_account, user: free_user, owner: free_user, status: status)
  end

  it "forces a Free user's self-created communicator to sandbox" do
    expect(free_user).to be_free
    expect(communicator.status).to eq(ChildAccount::SANDBOX)
  end

  it "reports is_demo strictly as a mirror of sandbox?, nothing more" do
    expect(communicator.is_demo?).to eq(communicator.sandbox?)
    expect(communicator.is_demo?).to be(true)

    communicator.update!(status: ChildAccount::ACTIVE)
    expect(communicator.is_demo?).to be(false)
  end

  # The half that matters: the flag above must not make the OWNER look like
  # test data anywhere the exclusions are actually applied.
  it "leaves the owner a real, non-demo user" do
    communicator # force the sandbox communicator into existence
    expect(free_user.demo_user?).to be(false)
    expect(User.demo_accounts).not_to include(free_user)
    expect(User.non_demo).to include(free_user)
  end

  # #876, the half that keeps getting re-reported. The values above were always
  # correct, but `is_demo` reads as "test data" to anyone holding the payload,
  # and `free_trial` was the OWNER's 14-day-from-signup window stapled onto a
  # communicator that has no subscription of its own. Neither is serialized now
  # — `status` is the whole answer, and the user payload owns `free_trial`.
  describe "the communicator payloads" do
    %i[api_view index_api_view vendor_api_view].each do |view_name|
      it "publishes status without is_demo or free_trial from ##{view_name}" do
        view = communicator.public_send(view_name, free_user)

        expect(view[:status]).to eq(ChildAccount::SANDBOX)
        expect(view).not_to have_key(:is_demo)
        expect(view).not_to have_key(:free_trial)
      end
    end

    it "still answers free_trial on the USER payload, which is who owns it" do
      expect(free_user.api_view).to have_key(:free_trial)
    end
  end

  it "keys demo_user? on the user's own identity, not on any communicator" do
    internal = create(:user, email: "someone@speakanyway.com")
    create(:child_account, user: internal, owner: internal, status: ChildAccount::ACTIVE)

    # An `active` communicator (is_demo: false) on an internal account is still
    # excluded, and a sandbox one on a real account still isn't.
    expect(internal.demo_user?).to be(true)
    expect(User.demo_accounts).to include(internal)
  end
end
