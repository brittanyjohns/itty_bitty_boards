# frozen_string_literal: true

require "rails_helper"

# #820 — the cap 422 was a bare prose string ("Maximum number of communicator
# accounts reached.") with no limit and no path, surfaced verbatim mid-form.
# The prose stays byte-identical (the frontend renders it today); the refusal
# now also carries a stable code and the numbers it was decided against.
RSpec.describe "API::ChildAccounts slot-limit error contract", type: :request do
  let(:clinician) do
    user = create(:user, plan_type: "clinician", created_at: 2.months.ago)
    user.setup_clinician_limits
    user.save!
    user
  end

  def fill_slots(user, count)
    count.times do |i|
      create(:child_account, user: user, owner: user, status: "active",
                             passcode: "x", username: "full-#{i}-#{SecureRandom.hex(2)}")
    end
  end

  describe "POST /api/child_accounts at the cap" do
    it "returns the error code and the limit alongside the unchanged prose" do
      fill_slots(clinician, 2)

      post "/api/child_accounts",
           params: { name: "Nina", username: "nina-#{SecureRandom.hex(2)}", password: "abc12345",
                     password_confirmation: "abc12345" },
           headers: auth_headers(clinician)

      expect(response).to have_http_status(:unprocessable_content)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Maximum number of communicator accounts reached.")
      expect(body["error_code"]).to eq("communicator_limit_reached")
      expect(body["limit"]).to eq(2)
      expect(body["count"]).to eq(2)
    end

    it "codes a sandbox quota refusal separately from a slot refusal" do
      user = create(:user, plan_type: "free", created_at: 2.months.ago)
      user.setup_free_limits
      user.save!
      limit = Permissions::CommunicatorLimits.sandbox_limit_for(user.settings)
      limit.times do |i|
        create(:child_account, user: user, owner: user, status: "sandbox",
                               passcode: nil, username: "sb-#{i}-#{SecureRandom.hex(2)}")
      end

      # A Free user's self-create is forced to sandbox, so this hits the
      # sandbox quota rather than the slot check.
      post "/api/child_accounts",
           params: { name: "Extra", username: "extra-#{SecureRandom.hex(2)}" },
           headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Sandbox communicator limit reached.")
      expect(body["error_code"]).to eq("sandbox_limit_reached")
      expect(body["limit"]).to eq(limit)
    end

    it "carries no error_code on success" do
      post "/api/child_accounts",
           params: { name: "Nina", username: "nina-#{SecureRandom.hex(2)}", password: "abc12345",
                     password_confirmation: "abc12345" },
           headers: auth_headers(clinician)

      expect(response).to have_http_status(:success)
      expect(JSON.parse(response.body)).not_to have_key("error_code")
    end
  end

  describe "Permissions::CommunicatorLimits" do
    it "appends the code without disturbing three-target destructuring" do
      fill_slots(clinician, 2)

      allowed, http_status, error = Permissions::CommunicatorLimits.can_create?(
        user: clinician, status: ChildAccount::ACTIVE
      )

      expect(allowed).to be(false)
      expect(http_status).to eq(:unprocessable_content)
      expect(error).to eq("Maximum number of communicator accounts reached.")
    end
  end
end
