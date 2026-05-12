require "rails_helper"

# Verifies Phase 3 enforcement: AI endpoints spend credits via CreditService
# and return 402 insufficient_credits when the balance is too low. Each AI
# endpoint is covered, plus the shape of the 402 body and admin bypass.
RSpec.describe "Credit enforcement on AI endpoints", type: :request do
  let(:user) { FactoryBot.create(:user) }

  def auth
    auth_headers(user)
  end

  describe "402 body shape" do
    it "includes feature, needed, balance, plan_credits, topup_credits, topup_url" do
      post "/api/scenarios", params: { scenario: { name: "x" } }, headers: auth
      expect(response).to have_http_status(402)
      body = JSON.parse(response.body)
      expect(body).to include(
        "error" => "insufficient_credits",
        "feature" => "scenario_create",
        "needed" => 10,
        "balance" => 0,
        "plan_credits" => 0,
        "topup_credits" => 0,
        "topup_url" => "/account/billing/topup",
      )
      expect(body["message"]).to match(/scenario/i)
    end
  end

  describe "spending the configured weight per feature" do
    before { CreditService.grant_plan!(user, amount: 1000, period_end: 30.days.from_now) }

    it "image_generation costs 5" do
      expect {
        post "/api/images/generate", params: { image: { label: "cat", image_prompt: "cat" } }, headers: auth
      }.to change { user.reload.plan_credits_balance }.by(-5)
    end

    it "word_suggestion costs 1" do
      # Stub the OpenAI call so the action doesn't actually hit the network
      allow_any_instance_of(Board).to receive(:get_word_suggestions).and_return(["red", "blue"])
      expect {
        get "/api/boards/words", params: { name: "school", num_of_words: 10 }, headers: auth
      }.to change { user.reload.plan_credits_balance }.by(-1)
    end

    it "scenario_create costs 10" do
      expect {
        post "/api/scenarios", params: { scenario: { name: "morning routine" } }, headers: auth
      }.to change { user.reload.plan_credits_balance }.by(-10)
    end
  end

  describe "admin bypass" do
    let(:admin) { FactoryBot.create(:admin_user) }

    it "lets admins call AI endpoints with zero credits" do
      expect(admin.plan_credits_balance).to eq(0)
      post "/api/scenarios",
           params: { scenario: { name: "morning routine" } },
           headers: auth_headers(admin)
      expect(response).not_to have_http_status(402)
      expect(admin.reload.plan_credits_balance).to eq(0) # not charged
    end
  end

  describe "drains plan credits before top-up" do
    before do
      CreditService.grant_plan!(user, amount: 3, period_end: 30.days.from_now)
      CreditService.grant_topup!(user, amount: 100, stripe_event_id: "evt_seed")
    end

    it "uses plan balance first for an image_generation call" do
      post "/api/images/generate", params: { image: { label: "cat", image_prompt: "cat" } }, headers: auth
      user.reload
      # cost 5 — plan had 3, topup absorbs 2
      expect(user.plan_credits_balance).to eq(0)
      expect(user.topup_credits_balance).to eq(98)
    end
  end
end
