require "rails_helper"

RSpec.describe "GET /api/v1/users/current", type: :request do
  include AuthHelpers

  let!(:user) { FactoryBot.create(:user, plan_type: "basic", plan_status: "active") }

  it "returns plan_status in the response" do
    get "/api/v1/users/current", headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json["user"]["plan_status"]).to eq("active")
  end

  it "returns plan_status = trialing for a trial user" do
    user.update!(plan_status: "trialing")

    get "/api/v1/users/current", headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    json = JSON.parse(response.body)
    expect(json["user"]["plan_status"]).to eq("trialing")
  end

  it "reconciles a stranded plan on the current endpoint" do
    user.update!(plan_type: "basic", plan_status: "canceled")

    get "/api/v1/users/current", headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    user.reload
    expect(user.plan_type).to eq("free")
    json = JSON.parse(response.body)
    expect(json["user"]["plan_type"]).to eq("free")
  end
end
