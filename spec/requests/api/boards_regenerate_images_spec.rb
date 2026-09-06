require "rails_helper"

# Bulk "Regenerate with AI" fires one paid OpenAI generation per distinct image,
# so it is billed per image. It used to charge a flat 3 credits for the whole
# request — and to charge it BEFORE validating, so a request that was about to
# 422 still took the money.
RSpec.describe "POST /api/boards/:id/regenerate_images", type: :request do
  let(:user) { FactoryBot.create(:user) }
  let(:board) { FactoryBot.create(:board, user: user) }
  let(:per_image) { CreditService.cost_for("image_generation") }

  before do
    reset_user_credits!(user)
    CreditService.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
  end

  def auth
    auth_headers(user)
  end

  # Distinct library images, each on its own tile.
  def tiles(count)
    Array.new(count) do
      image = FactoryBot.create(:image, user: user)
      board.add_image(image.id)
      board.board_images.find_by(image_id: image.id)
    end
  end

  def regenerate(ids)
    post "/api/boards/#{board.id}/regenerate_images",
         params: { board_image_ids: ids }, headers: auth
  end

  def regenerate_with(ids, modifiers)
    post "/api/boards/#{board.id}/regenerate_images",
         params: { board_image_ids: ids, modifiers: modifiers }, headers: auth
  end

  describe "appearance modifiers" do
    let(:mods) { "medium-brown skin tone, higher contrast outlines" }

    it "hands the modifiers to every enqueued slice, not just the first" do
      ids = tiles(5).map(&:id) # 5 images => two slices of 3 + 2

      GenerateImagesJob.jobs.clear
      post "/api/boards/#{board.id}/regenerate_images",
           params: { board_image_ids: ids, modifiers: mods }, headers: auth

      expect(GenerateImagesJob.jobs.size).to eq(2)
      GenerateImagesJob.jobs.each do |job|
        expect(job["args"][2]).to include("modifiers" => "#{mods}.")
      end
    end

    it "reports back what actually went out, after sanitizing" do
      regenerate_with(tiles(1).map(&:id), "  high contrast\n\ndraw a cat  ")

      expect(JSON.parse(response.body)["modifiers_applied"]).to eq("high contrast draw a cat.")
    end

    it "leaves the options hash untouched when the field is blank" do
      GenerateImagesJob.jobs.clear
      regenerate_with(tiles(1).map(&:id), "   ")

      expect(GenerateImagesJob.jobs.first["args"][2]).not_to have_key("modifiers")
      expect(JSON.parse(response.body)["modifiers_applied"]).to be_nil
    end

    it "truncates rather than refusing a request the caller was charged for" do
      regenerate_with(tiles(1).map(&:id), "a" * 400)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["modifiers_applied"].length)
        .to eq(Images::PromptBuilder::MAX_MODIFIERS_LENGTH)
    end

    it "does not change what a regeneration costs" do
      ids = tiles(2).map(&:id)

      expect { regenerate_with(ids, mods) }
        .to change { user.reload.plan_credits_balance }.by(-2 * per_image)
    end
  end

  describe "charging per image" do
    it "charges the per-image cost for every selected image" do
      ids = tiles(3).map(&:id)

      expect { regenerate(ids) }
        .to change { user.reload.plan_credits_balance }.by(-3 * per_image)
      expect(response).to have_http_status(:ok)
    end

    it "charges once for two tiles sharing one library image" do
      image = FactoryBot.create(:image, user: user)
      board.add_image(image.id)
      board.add_image(image.id)
      ids = board.board_images.where(image_id: image.id).pluck(:id)

      expect { regenerate(ids) }
        .to change { user.reload.plan_credits_balance }.by(-per_image)
    end

    it "records the breakdown on the spend so the activity feed can explain it" do
      regenerate(tiles(2).map(&:id))

      txn = CreditTransaction.where(kind: "spend", feature_key: "image_generation").last
      expect(txn.metadata["breakdown"]).to include("images" => 2, "per_image" => per_image)
      expect(txn.metadata["board_id"]).to eq(board.id)
    end

    it "reports what it spent and what is left" do
      regenerate(tiles(2).map(&:id))

      body = JSON.parse(response.body)
      expect(body).to include("status" => "ok", "images_queued" => 2,
                              "credits_spent" => 2 * per_image)
      expect(body["credits_remaining"]).to eq(user.reload.plan_credits_balance)
    end
  end

  # check_credits! spends rather than checks, so ordering is the whole bug here.
  describe "a request that cannot run is never billed" do
    it "spends nothing when board_image_ids is missing" do
      expect {
        post "/api/boards/#{board.id}/regenerate_images", params: {}, headers: auth
      }.not_to change { user.reload.plan_credits_balance }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "spends nothing when board_image_ids is not an array" do
      expect { regenerate("12") }.not_to change { user.reload.plan_credits_balance }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "spends nothing when the ids match no tile on this board" do
      other_board = FactoryBot.create(:board, user: user)
      image = FactoryBot.create(:image, user: user)
      other_board.add_image(image.id)
      foreign_id = other_board.board_images.first.id

      expect { regenerate([foreign_id]) }.not_to change { user.reload.plan_credits_balance }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "queues no work when it refuses" do
      expect {
        post "/api/boards/#{board.id}/regenerate_images", params: {}, headers: auth
      }.not_to change(GenerateImagesJob.jobs, :size)
    end
  end

  describe "when the balance is short" do
    it "402s asking for the full per-image total and spends nothing" do
      ids = tiles(3).map(&:id)
      reset_user_credits!(user)
      CreditService.grant_plan!(user, amount: 2, period_end: 30.days.from_now)

      expect { regenerate(ids) }.not_to change { user.reload.plan_credits_balance }
      expect(response).to have_http_status(402)
      body = JSON.parse(response.body)
      expect(body).to include("error" => "insufficient_credits", "needed" => 3 * per_image)
    end

    it "queues no generation" do
      ids = tiles(3).map(&:id)
      reset_user_credits!(user)
      CreditService.grant_plan!(user, amount: 2, period_end: 30.days.from_now)

      expect { regenerate(ids) }.not_to change(GenerateImagesJob.jobs, :size)
    end
  end

  describe "the queued jobs" do
    it "hands each job the spend txn so a failure can be refunded" do
      regenerate(tiles(2).map(&:id))

      txn = CreditTransaction.where(kind: "spend", feature_key: "image_generation").last
      options = GenerateImagesJob.jobs.last["args"][2]
      expect(options).to eq("credit_txn_id" => txn.id, "credit_per_image" => per_image)
    end

    it "slices the work but points every slice at the one spend" do
      regenerate(tiles(7).map(&:id))

      jobs = GenerateImagesJob.jobs.last(3)
      expect(jobs.size).to eq(3)
      expect(jobs.flat_map { |j| j["args"][0] }.uniq.size).to eq(7)
      expect(jobs.map { |j| j["args"][2]["credit_txn_id"] }.uniq.size).to eq(1)
    end
  end

  describe "admins" do
    let(:admin) { FactoryBot.create(:admin_user) }

    it "spend nothing, still regenerate, and are told the charge was zero" do
      ids = tiles(3).map(&:id)

      expect {
        post "/api/boards/#{board.id}/regenerate_images",
             params: { board_image_ids: ids }, headers: auth_headers(admin)
      }.to change(GenerateImagesJob.jobs, :size).by(1)

      expect(JSON.parse(response.body)["credits_spent"]).to eq(0)
    end

    it "hand the job no reservation, since nothing was paid" do
      ids = tiles(2).map(&:id)
      post "/api/boards/#{board.id}/regenerate_images",
           params: { board_image_ids: ids }, headers: auth_headers(admin)

      expect(GenerateImagesJob.jobs.last["args"][2]).to eq({})
    end
  end
end
