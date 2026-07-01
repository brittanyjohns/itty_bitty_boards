# frozen_string_literal: true

require "rails_helper"

# Issue #439 — owner picks which communicators stay signable when over the
# plan's slot limit (the mirror of the board "make_editable" pick). The chosen
# ids keep private sign-in; the rest enter fallback mode (public MySpeak page
# stays open). Endpoint: POST /api/child_accounts/keep_signable.
RSpec.describe "API::ChildAccounts keep_signable (#439)", type: :request do
  let(:owner) { create(:user, plan_type: "pro") }

  # Three active communicators, most-recently-active first (a0, a1, a2).
  let!(:accounts) do
    Array.new(3) do |i|
      acct = create(:child_account, user: owner, owner: owner, status: ChildAccount::ACTIVE,
                                    username: "comm_#{owner.id}_#{i}", passcode: "pass#{i}0")
      acct.update_column(:last_sign_in_at, (i + 1).hours.ago)
      acct
    end
  end

  before { owner.update!(plan_type: "basic") } # Basic slot limit = 2

  it "pins the owner's chosen communicators and falls back the rest" do
    a0, a1, a2 = accounts

    post "/api/child_accounts/keep_signable",
      params: { communicator_ids: [a2.id, a0.id] },
      headers: auth_headers(owner)

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["kept_communicator_ids"]).to eq([a2.id, a0.id])
    expect(body["communicator_slot_limit"]).to eq(2)

    expect(a2.reload.fallback_mode?).to be(false)
    expect(a0.reload.fallback_mode?).to be(false)
    expect(a1.reload.fallback_mode?).to be(true)
  end

  it "ignores communicators owned by someone else" do
    a0 = accounts.first
    stranger = create(:child_account, status: ChildAccount::ACTIVE)

    post "/api/child_accounts/keep_signable",
      params: { communicator_ids: [a0.id, stranger.id] },
      headers: auth_headers(owner)

    expect(JSON.parse(response.body)["kept_communicator_ids"]).to eq([a0.id])
  end

  it "requires authentication" do
    post "/api/child_accounts/keep_signable", params: { communicator_ids: [] }
    expect(response).to have_http_status(:unauthorized)
  end
end
