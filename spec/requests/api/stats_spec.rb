require "rails_helper"

RSpec.describe "GET /api/stats", type: :request do
  let(:stats_token) { "test-stats-secret-token-12345" }
  let(:auth_header) { { "Authorization" => "Bearer #{stats_token}" } }

  let(:stripe_revenue_result) do
    {
      source: "stripe",
      cached_at: Time.current.iso8601,
      active_subscriptions: 85,
      mrr_usd: 59.67,
      new_subs_7d: 2,
      plan_breakdown: { "free_plan" => 52, "basic_plan" => 14 },
    }
  end

  before do
    allow(Stats::StripeRevenue).to receive(:call).and_return(stripe_revenue_result)
  end

  context "without Authorization header" do
    it "returns 401" do
      with_env("STATS_TOKEN" => stats_token) do
        get "/api/stats"
        expect(response).to have_http_status(:unauthorized)
        expect(parsed_body["error"]).to eq("Unauthorized")
      end
    end
  end

  context "with wrong token" do
    it "returns 401" do
      with_env("STATS_TOKEN" => stats_token) do
        get "/api/stats", headers: { "Authorization" => "Bearer wrong-token" }
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  context "when STATS_TOKEN env is unset" do
    it "returns 401 (fail-closed)" do
      with_env("STATS_TOKEN" => nil) do
        get "/api/stats", headers: auth_header
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  context "when STATS_TOKEN env is blank" do
    it "returns 401 (fail-closed)" do
      with_env("STATS_TOKEN" => "") do
        get "/api/stats", headers: auth_header
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  context "with valid token" do
    let!(:admin_user) { FactoryBot.create(:user, role: "admin") }
    let!(:free_user) { FactoryBot.create(:user, plan_type: "free") }
    let!(:paid_user) { FactoryBot.create(:user, plan_type: "basic") }
    let!(:board) { FactoryBot.create(:board, user: free_user) }

    it "returns 200 with expected JSON structure" do
      with_env("STATS_TOKEN" => stats_token) do
        get "/api/stats", headers: auth_header

        expect(response).to have_http_status(:ok)
        json = parsed_body

        expect(json).to have_key("generated_at")
        expect(json["app"]["status"]).to eq("ok")

        expect(json["users"]["total"]).to eq(2)
        expect(json["users"]["paid"]).to eq(1)
        expect(json["users"]["free"]).to eq(1)

        expect(json["boards"]["total"]).to be >= 1

        expect(json["communicators"]).to have_key("total")
        expect(json["communicators"]).to have_key("sandbox")
        expect(json["communicators"]).to have_key("loaner")
        expect(json["communicators"]).to have_key("active")
        expect(json["communicators"]).to have_key("archived")

        expect(json["revenue"]["source"]).to eq("stripe")
        expect(json["revenue"]["active_subscriptions"]).to eq(85)
        expect(json["revenue"]["mrr_usd"]).to eq(59.67)
      end
    end
  end

  context "with communicator status breakdown" do
    let!(:user) { FactoryBot.create(:user) }

    before do
      FactoryBot.create(:child_account, user: user, status: "sandbox")
      FactoryBot.create(:child_account, user: user, status: "active")
      FactoryBot.create(:child_account, user: user, status: "active", archived_at: Time.current)
    end

    it "counts communicators correctly including archived in total" do
      with_env("STATS_TOKEN" => stats_token) do
        get "/api/stats", headers: auth_header

        json = parsed_body
        expect(json["communicators"]["total"]).to eq(3)
        expect(json["communicators"]["sandbox"]).to eq(1)
        expect(json["communicators"]["active"]).to eq(1)
        expect(json["communicators"]["archived"]).to eq(1)
      end
    end
  end

  context "when Stripe is down" do
    before do
      allow(Stats::StripeRevenue).to receive(:call).and_return(
        source: "stripe",
        error: true,
        cached_at: Time.current.iso8601,
        active_subscriptions: nil,
        mrr_usd: nil,
        new_subs_7d: nil,
        plan_breakdown: nil,
      )
    end

    it "returns 200 with counts and degraded revenue" do
      user = FactoryBot.create(:user, plan_type: "free")
      with_env("STATS_TOKEN" => stats_token) do
        get "/api/stats", headers: auth_header

        expect(response).to have_http_status(:ok)
        json = parsed_body
        expect(json["revenue"]["error"]).to eq(true)
        expect(json["users"]["total"]).to be >= 1
      end
    end
  end

  private

  def parsed_body
    JSON.parse(response.body)
  end

  def with_env(overrides, &block)
    old_values = overrides.map { |k, _| [k, ENV[k]] }.to_h
    overrides.each { |k, v| ENV[k] = v }
    yield
  ensure
    old_values.each { |k, v| ENV[k] = v }
  end
end
