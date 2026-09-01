# frozen_string_literal: true

require "rails_helper"

# The Clinician plan's advertised workflow, end to end: set up a communicator,
# hand it to the family, get the slot back. Every step was unreachable before
# #820 (the lend endpoint 403'd on `pro_required`), so the recycling half had
# never run for a clinician-owned loaner — this exercises it rather than
# assuming `claim_by!` is plan-agnostic.
RSpec.describe "Clinician loaner lifecycle", type: :request do
  let(:clinician) do
    user = create(:user, plan_type: "clinician", created_at: 2.months.ago)
    user.setup_clinician_limits
    user.save!
    user
  end

  let(:family) do
    user = create(:user, created_at: 2.months.ago)
    user.setup_free_limits
    user.save!
    user
  end

  def slots_used(user)
    Permissions::CommunicatorLimits.owned_slot_count(user.reload)
  end

  it "lends, hands off, and frees the clinician's slot on claim" do
    sandbox = create(:child_account, user: clinician, owner: clinician,
                                     status: "sandbox", passcode: nil)
    sandbox.ensure_team!(creator: clinician)

    expect(slots_used(clinician)).to eq(0)

    post "/api/child_accounts/#{sandbox.id}/lend", headers: auth_headers(clinician)
    expect(response).to have_http_status(:ok)

    loaner = sandbox.reload
    expect(loaner.status).to eq("loaner")
    expect(loaner.claim_token).to be_present
    # A loaner counts against the lender's slot while it is out on loan.
    expect(slots_used(clinician)).to eq(1)

    post "/api/communicator_claims/#{loaner.claim_token}/claim", headers: auth_headers(family)
    expect(response).to have_http_status(:ok)

    claimed = loaner.reload
    expect(claimed.status).to eq("active")
    expect(claimed.owner_id).to eq(family.id)

    # The whole point of the plan: the slot comes back.
    expect(slots_used(clinician)).to eq(0)
    expect(slots_used(family)).to eq(1)
    # The clinician stays on the team as a supervisor after the hand-off.
    expect(claimed.primary_team.team_users.find_by(user_id: clinician.id).role)
      .to eq("supervisor")
  end

  it "lets the clinician lend again once a slot has recycled" do
    two = Array.new(2) do |i|
      account = create(:child_account, user: clinician, owner: clinician,
                                       status: "sandbox", passcode: nil,
                                       username: "clin-#{i}-#{SecureRandom.hex(2)}")
      account.ensure_team!(creator: clinician)
      post "/api/child_accounts/#{account.id}/lend", headers: auth_headers(clinician)
      expect(response).to have_http_status(:ok)
      account.reload
    end

    # Both slots are now out on loan — a third lend is refused by slot math.
    third = create(:child_account, user: clinician, owner: clinician,
                                   status: "sandbox", passcode: nil)
    post "/api/child_accounts/#{third.id}/lend", headers: auth_headers(clinician)
    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)["error_code"]).to eq("communicator_limit_reached")

    # One family claims; the freed slot makes the third lend succeed.
    post "/api/communicator_claims/#{two.first.claim_token}/claim", headers: auth_headers(family)
    expect(response).to have_http_status(:ok)

    post "/api/child_accounts/#{third.id}/lend", headers: auth_headers(clinician)
    expect(response).to have_http_status(:ok)
    expect(third.reload.status).to eq("loaner")
  end
end
