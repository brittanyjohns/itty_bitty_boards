# frozen_string_literal: true

require "rails_helper"

# The create/update failure bodies grew a `field_errors` key so the frontend can
# attach a message to the input that caused it. ADDITIVE by design: `error` and
# `errors` keep the exact flat-string shape the current frontend reads, so the
# two repos ship in either order.
RSpec.describe "API::ChildAccounts field_errors", type: :request do
  let(:user) { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:stranger) { create(:user, created_at: 2.months.ago) }

  describe "POST /api/child_accounts with a taken username" do
    before { create(:child_account, user: stranger, owner: stranger, username: "leo") }

    def create_leo
      post "/api/child_accounts",
           params: { name: "Leo", username: "leo", status: ChildAccount::ACTIVE, password: "1234", password_confirmation: "1234" },
           headers: auth_headers(user)
      JSON.parse(response.body)
    end

    it "keys the message by field" do
      body = create_leo

      expect(response).to have_http_status(:unprocessable_content)
      expect(body["field_errors"]).to eq("username" => ["Username has already been taken"])
    end

    it "leaves error and errors as the unchanged flat strings" do
      body = create_leo

      expect(body["error"]).to be_a(String)
      expect(body["error"]).to include("has already been taken")
      expect(body["errors"]).to eq(body["error"])
    end
  end

  it "carries every invalid field, not just the first" do
    create(:child_account, user: stranger, owner: stranger, username: "leo")

    post "/api/child_accounts",
         params: {
           name: "Leo",
           username: "leo",
           status: ChildAccount::ACTIVE,
           password: "1234",
           password_confirmation: "1234",
           age_band: "99-100",
         },
         headers: auth_headers(user)

    body = JSON.parse(response.body)
    expect(response).to have_http_status(:unprocessable_content)
    expect(body["field_errors"].keys).to include("username", "age_band")
  end

  describe "PATCH /api/child_accounts/:id" do
    let!(:communicator) do
      create(:child_account, user: user, owner: user, username: "mine", status: ChildAccount::ACTIVE, passcode: "1234")
    end

    before { create(:child_account, user: stranger, owner: stranger, username: "leo") }

    it "keys update failures by field too" do
      patch "/api/child_accounts/#{communicator.id}",
            params: { username: "leo" },
            headers: auth_headers(user)

      body = JSON.parse(response.body)
      expect(response).to have_http_status(:unprocessable_content)
      expect(body["field_errors"]).to eq("username" => ["Username has already been taken"])
      expect(body["errors"]).to eq(body["error"])
      expect(body["error"]).to include("has already been taken")
    end

    it "omits field_errors from a hand-written refusal that has no validation behind it" do
      patch "/api/child_accounts/#{communicator.id}",
            params: { password: "1234", password_confirmation: "9999" },
            headers: auth_headers(user)

      body = JSON.parse(response.body)
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).not_to have_key("field_errors")
    end
  end
end
