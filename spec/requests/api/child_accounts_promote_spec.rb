# frozen_string_literal: true

require "rails_helper"

# Issue #159 (B3) — promote sandbox to loaner via the API.
RSpec.describe "API::ChildAccounts promote_to_loaner", type: :request do
  let(:user) { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let!(:sandbox) { create(:child_account, user: user, owner: user, status: "sandbox", passcode: nil) }

  it "promotes a sandbox to loaner" do
    post "/api/child_accounts/#{sandbox.id}/promote_to_loaner",
      params: { passcode: "rentme01" },
      headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(sandbox.reload.status).to eq("loaner")
    expect(sandbox.passcode).to eq("rentme01")
  end

  it "rejects promotion when the owner is out of slots" do
    5.times do |i|
      create(:child_account, user: user, owner: user, status: "loaner",
                             username: "p#{i}-#{SecureRandom.hex(2)}", passcode: "x#{i}")
    end

    post "/api/child_accounts/#{sandbox.id}/promote_to_loaner",
      params: { passcode: "rentme01" },
      headers: auth_headers(user)

    expect(response).to have_http_status(:unprocessable_content)
    expect(sandbox.reload.status).to eq("sandbox")
  end

  it "refuses to promote a non-sandbox" do
    sandbox.update!(status: "loaner", passcode: "existing01")

    post "/api/child_accounts/#{sandbox.id}/promote_to_loaner",
      headers: auth_headers(user)

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "rejects unauthorized users" do
    other = create(:user)
    post "/api/child_accounts/#{sandbox.id}/promote_to_loaner",
      headers: auth_headers(other)

    expect(response).to have_http_status(:unauthorized)
  end
end
