# spec/requests/api/board_images_rate_limit_spec.rb
#
# Phase 3 of usage-based pricing replaced the Redis monthly counter with the
# credit ledger for AI gating, so these endpoints no longer return 429 when
# limited — they return 402 insufficient_credits. The spec used to assert
# 429 on the 6th call; it now asserts 402 the moment the credit balance
# drops below the per-call cost.
#
# The broader 402 + spend-weight behavior across all AI endpoints lives in
# spec/requests/api/credit_enforcement_spec.rb. This file is kept for the
# board-image-specific edit/variation endpoints + missing-image edge case.

require "rails_helper"

RSpec.describe "BoardImages AI gating (credits)", type: :request do
  def j
    JSON.parse(response.body) rescue {}
  end

  before do
    allow_any_instance_of(API::ApplicationController)
      .to receive(:authenticate_token!).and_return(true)
    allow_any_instance_of(API::ApplicationController)
      .to receive(:current_user).and_return(user)
    # These tests need an explicit balance; wipe the after_create plan_grant.
    reset_user_credits!(user)
  end

  let!(:user)        { create(:user) }
  let!(:board)       { create(:board, user: user) }
  let!(:image)       { create(:image, user: user) }
  let!(:board_image) { create(:board_image, board: board, image: image) }

  describe "POST /api/board_images/:id/create_edit" do
    it "returns 402 insufficient_credits when balance is below image_edit cost (5)" do
      post "/api/board_images/#{board_image.id}/create_edit", params: { prompt: "x" }
      expect(response.status).to eq(402)
      expect(j["error"]).to eq("insufficient_credits")
      expect(j["feature"]).to eq("image_edit")
      expect(j["needed"]).to eq(5)
    end

    it "succeeds while credits are available, then blocks once exhausted" do
      # image_edit costs 5; grant exactly 3 calls' worth so the 4th is blocked.
      CreditService.grant_plan!(user, amount: 15, period_end: 30.days.from_now)

      3.times do
        post "/api/board_images/#{board_image.id}/create_edit", params: { prompt: "x" }
        expect(response.status).not_to eq(402)
      end

      post "/api/board_images/#{board_image.id}/create_edit", params: { prompt: "x" }
      expect(response.status).to eq(402)
      expect(j["error"]).to eq("insufficient_credits")
    end
  end

  describe "POST /api/board_images/:id/create_variation" do
    it "returns 402 with feature=image_variation" do
      post "/api/board_images/#{board_image.id}/create_variation"
      expect(response.status).to eq(402)
      expect(j["feature"]).to eq("image_variation")
      expect(j["needed"]).to eq(3)
    end
  end

  context "when the board image is missing" do
    it "returns 404/422 (not 402) — auth/find layer runs before credit gating" do
      CreditService.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
      post "/api/board_images/999999/create_image_edit", params: { prompt: "x" }
      expect([422, 404]).to include(response.status)
    end
  end
end
