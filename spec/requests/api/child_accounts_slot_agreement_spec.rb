# frozen_string_literal: true

require "rails_helper"

# The invariant #824 exists for: the slot numbers a client renders and the
# answer a create actually gets are the same answer.
#
# Before this, `comm_account_limit_reached` summed the paid AND sandbox limits
# against EVERY communicator, so a clinician at 2/2 with one out on loan read
# `false` there, `true` in `paid_comm_account_limit_reached`, and 422'd on the
# create. The pre-form limit card gated on the first field and never rendered;
# a second panel picked the other one and printed "2 of 2 slots in use" above
# "No slots available."
RSpec.describe "Communicator slot reporting", type: :request do
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

  def slots(user)
    get "/api/v1/users/current", headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body).fetch("user")
  end

  # The whole point: ask the payload, then ask the server, and require the
  # same answer. Returns the create response so a caller can assert further.
  def expect_payload_to_predict_create(user, username:)
    body = slots(user)
    predicted = body.dig("communicator_slots", "limit_reached")

    # Every published flag says the same thing as the derived object.
    expect(body["comm_account_limit_reached"]).to eq(predicted)
    expect(body["paid_comm_account_limit_reached"]).to eq(predicted)

    post "/api/child_accounts",
         params: { username: username, name: username, status: "active",
                   password: "s3cret-pass", password_confirmation: "s3cret-pass" },
         headers: auth_headers(user)

    refused = response.status != 201 && response.status != 200
    expect(refused).to eq(predicted),
                       "communicator_slots.limit_reached said #{predicted} but the create " \
                       "returned #{response.status} (#{response.body})"
    [body, response]
  end

  def lend!(account)
    post "/api/child_accounts/#{account.id}/lend", headers: auth_headers(clinician)
    expect(response).to have_http_status(:ok)
    account.reload
  end

  def sandbox_for(clinician, suffix)
    account = create(:child_account, user: clinician, owner: clinician,
                                     status: "sandbox", passcode: nil,
                                     username: "clin-#{suffix}-#{SecureRandom.hex(2)}")
    account.ensure_team!(creator: clinician)
    account
  end

  it "reports slots free and lets the create through when the plan has room" do
    body, = expect_payload_to_predict_create(clinician, username: "first-#{SecureRandom.hex(2)}")

    expect(body["communicator_slots"]).to include(
      "limit" => 2, "used" => 0, "available" => 2,
      "on_loan" => 0, "active" => 0, "limit_reached" => false
    )
  end

  it "counts a loaner against the slot and refuses the create — the walkthrough state" do
    active = sandbox_for(clinician, "active")
    lent = sandbox_for(clinician, "lent")

    active.update!(status: "active", passcode: "s3cret-pass")
    lend!(lent)

    body, create_response = expect_payload_to_predict_create(clinician, username: "third-#{SecureRandom.hex(2)}")

    expect(body["communicator_slots"]).to include(
      "limit" => 2, "used" => 2, "available" => 0,
      "on_loan" => 1, "active" => 1, "limit_reached" => true
    )
    # The numbers the refusal carries are the numbers the payload published.
    expect(create_response).to have_http_status(:unprocessable_content)
    refusal = JSON.parse(create_response.body)
    expect(refusal["error_code"]).to eq("communicator_limit_reached")
    expect(refusal["limit"]).to eq(body.dig("communicator_slots", "limit"))
    expect(refusal["count"]).to eq(body.dig("communicator_slots", "used"))
  end

  it "frees the slot on claim, and every flag moves together — lend, cap, claim" do
    first = lend!(sandbox_for(clinician, "one"))
    lend!(sandbox_for(clinician, "two"))

    # Both slots out on loan: still at cap, because the plan returns a slot on
    # CLAIM, not on lend.
    body, = expect_payload_to_predict_create(clinician, username: "capped-#{SecureRandom.hex(2)}")
    expect(body["communicator_slots"]).to include(
      "used" => 2, "on_loan" => 2, "active" => 0, "available" => 0, "limit_reached" => true
    )

    post "/api/communicator_claims/#{first.claim_token}/claim", headers: auth_headers(family)
    expect(response).to have_http_status(:ok)

    body, = expect_payload_to_predict_create(clinician, username: "recycled-#{SecureRandom.hex(2)}")
    expect(body["communicator_slots"]).to include(
      "used" => 1, "on_loan" => 1, "active" => 0, "available" => 1, "limit_reached" => false
    )

    # The family that claimed now holds the slot on their side.
    expect(slots(family)["communicator_slots"]).to include(
      "limit" => 1, "used" => 1, "active" => 1, "available" => 0, "limit_reached" => true
    )
  end

  it "honours a communicator_slot_limit override on both the payload and the gate" do
    clinician.update!(settings: clinician.settings.merge("communicator_slot_limit" => 1))
    sandbox_for(clinician, "only").update!(status: "active", passcode: "s3cret-pass")

    body, create_response = expect_payload_to_predict_create(clinician, username: "over-#{SecureRandom.hex(2)}")

    # `paid_communicator_limit` still says 2; the override is what is enforced,
    # so it is what the payload has to publish.
    expect(clinician.settings["paid_communicator_limit"]).to eq(2)
    expect(body["communicator_slots"]).to include("limit" => 1, "used" => 1, "limit_reached" => true)
    expect(body["comm_account_limit"]).to eq(1)
    expect(body["communicator_slot_limit"]).to eq(1)
    expect(create_response).to have_http_status(:unprocessable_content)
  end
end
