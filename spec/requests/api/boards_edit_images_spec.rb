require "rails_helper"

# Bulk "Edit pictures with a prompt" runs one paid OpenAI image EDIT per selected
# tile against the art that tile is already showing. Same credit shape as
# regenerate_images (validate -> count -> charge -> enqueue), with one deliberate
# difference: the partition of editable-vs-picture-less tiles happens BEFORE the
# charge, so a tile that can never run is never billed.
RSpec.describe "POST /api/boards/:id/edit_images", type: :request do
  let(:user) { FactoryBot.create(:user) }
  let(:board) { FactoryBot.create(:board, user: user) }
  let(:per_image) { CreditService.cost_for("image_edit") }
  let(:prompt) { "warmer skin tone" }

  before do
    reset_user_credits!(user)
    CreditService.grant_plan!(user, amount: 200, period_end: 30.days.from_now)
  end

  def auth
    auth_headers(user)
  end

  def tiles(count)
    Array.new(count) do
      image = FactoryBot.create(:image, user: user, src_url: "https://cdn.example.com/#{SecureRandom.hex(4)}.webp")
      board.add_image(image.id)
      board.board_images.find_by(image_id: image.id)
    end
  end

  # BoardImage#set_defaults seeds display_image_url from image.src_url on create,
  # so the blank has to be written AFTER the tile exists.
  def picture_less_tile
    bi = tiles(1).first
    bi.image.update!(src_url: nil)
    bi.update_column(:display_image_url, "")
    bi
  end

  def edit(ids, body = {})
    post "/api/boards/#{board.id}/edit_images",
         params: { board_image_ids: ids, prompt: prompt }.merge(body), headers: auth
  end

  describe "charging per tile" do
    it "charges the per-image cost for every editable tile" do
      ids = tiles(3).map(&:id)

      expect { edit(ids) }.to change { user.reload.plan_credits_balance }.by(-3 * per_image)
      expect(response).to have_http_status(:ok)
    end

    # The deliberate difference from regenerate: an edit writes the TILE's own
    # display_image_url, so two tiles sharing one library Image are two pictures.
    it "charges twice for two tiles sharing one library image" do
      image = FactoryBot.create(:image, user: user, src_url: "https://cdn.example.com/a.webp")
      board.add_image(image.id)
      board.add_image(image.id)
      ids = board.board_images.where(image_id: image.id).pluck(:id)

      expect { edit(ids) }.to change { user.reload.plan_credits_balance }.by(-2 * per_image)
    end

    it "records the breakdown on the spend" do
      edit(tiles(2).map(&:id))

      txn = CreditTransaction.where(kind: "spend", feature_key: "image_edit").last
      expect(txn.metadata["breakdown"]).to include("images" => 2, "per_image" => per_image)
      expect(txn.metadata["board_id"]).to eq(board.id)
    end

    it "reports what it spent and what is left" do
      edit(tiles(2).map(&:id))

      body = JSON.parse(response.body)
      expect(body).to include("status" => "ok", "images_queued" => 2,
                              "credits_spent" => 2 * per_image)
      expect(body["credits_remaining"]).to eq(user.reload.plan_credits_balance)
    end
  end

  describe "tiles with no picture to edit" do
    it "excludes them from both the charge and the queue, and names them" do
      editable = tiles(2).map(&:id)
      skipped = picture_less_tile

      expect { edit(editable + [skipped.id]) }
        .to change { user.reload.plan_credits_balance }.by(-2 * per_image)

      body = JSON.parse(response.body)
      expect(body["images_queued"]).to eq(2)
      expect(body["skipped_board_image_ids"]).to eq([skipped.id])
      expect(EditBoardImagesJob.jobs.last["args"][1]).to match_array(editable)
    end

    it "422s and spends nothing when every selected tile is picture-less" do
      skipped = picture_less_tile

      expect { edit([skipped.id]) }.not_to change { user.reload.plan_credits_balance }
      expect(response).to have_http_status(:unprocessable_content)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("no_editable_images")
      expect(body["skipped_board_image_ids"]).to eq([skipped.id])
    end

    it "queues nothing in that case" do
      skipped = picture_less_tile
      expect { edit([skipped.id]) }.not_to change(EditBoardImagesJob.jobs, :size)
    end
  end

  describe "validation, before any money moves" do
    it "422s a blank prompt and spends nothing" do
      ids = tiles(2).map(&:id)

      expect { edit(ids, prompt: "   ") }.not_to change { user.reload.plan_credits_balance }
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("prompt_required")
    end

    it "422s a missing board_image_ids and spends nothing" do
      expect {
        post "/api/boards/#{board.id}/edit_images", params: { prompt: prompt }, headers: auth
      }.not_to change { user.reload.plan_credits_balance }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "422s ids matching no tile on this board and spends nothing" do
      other = FactoryBot.create(:board, user: user)
      image = FactoryBot.create(:image, user: user)
      other.add_image(image.id)
      stranger = other.board_images.first

      expect { edit([stranger.id]) }.not_to change { user.reload.plan_credits_balance }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "truncates an over-long prompt rather than refusing it" do
      edit(tiles(1).map(&:id), prompt: "a" * 900)

      expect(response).to have_http_status(:ok)
      expect(EditBoardImagesJob.jobs.last["args"][2].length)
        .to eq(API::BoardsController::MAX_EDIT_PROMPT_LENGTH)
    end
  end

  describe "when the balance is short" do
    before do
      reset_user_credits!(user)
      CreditService.grant_plan!(user, amount: per_image, period_end: 30.days.from_now)
    end

    it "402s asking for the full per-tile total and spends nothing" do
      ids = tiles(3).map(&:id)

      expect { edit(ids) }.not_to change { user.reload.plan_credits_balance }
      expect(response).to have_http_status(402)
      expect(JSON.parse(response.body)).to include("error" => "insufficient_credits",
                                                   "needed" => 3 * per_image)
    end

    it "queues no edits" do
      expect { edit(tiles(3).map(&:id)) }.not_to change(EditBoardImagesJob.jobs, :size)
    end
  end

  describe "the queued jobs" do
    it "hands each job the spend txn so a failure can be refunded" do
      edit(tiles(2).map(&:id))

      txn = CreditTransaction.where(kind: "spend", feature_key: "image_edit").last
      expect(EditBoardImagesJob.jobs.last["args"][4])
        .to eq("credit_txn_id" => txn.id, "credit_per_image" => per_image)
    end

    it "slices the work but points every slice at the one spend" do
      edit(tiles(7).map(&:id))

      jobs = EditBoardImagesJob.jobs.last(3)
      expect(jobs.size).to eq(3)
      expect(jobs.flat_map { |j| j["args"][1] }.uniq.size).to eq(7)
      expect(jobs.map { |j| j["args"][4]["credit_txn_id"] }.uniq.size).to eq(1)
    end

    it "marks the queued tiles editing" do
      ids = tiles(2).map(&:id)
      edit(ids)

      expect(BoardImage.where(id: ids).pluck(:status).uniq).to eq(["editing"])
    end

    it "defaults transparency off, matching the single-tile path" do
      edit(tiles(1).map(&:id))
      expect(EditBoardImagesJob.jobs.last["args"][3]).to be(false)
    end
  end

  describe "permission" do
    it "refuses a board the caller does not own" do
      stranger = FactoryBot.create(:user)
      ids = tiles(1).map(&:id)

      expect {
        post "/api/boards/#{board.id}/edit_images",
             params: { board_image_ids: ids, prompt: prompt }, headers: auth_headers(stranger)
      }.not_to change(EditBoardImagesJob.jobs, :size)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "admins" do
    let(:admin) { FactoryBot.create(:admin_user) }

    it "spend nothing, still edit, and are told the charge was zero" do
      ids = tiles(2).map(&:id)

      expect {
        post "/api/boards/#{board.id}/edit_images",
             params: { board_image_ids: ids, prompt: prompt }, headers: auth_headers(admin)
      }.to change(EditBoardImagesJob.jobs, :size).by(1)

      expect(JSON.parse(response.body)["credits_spent"]).to eq(0)
    end

    it "hand the job no reservation, since nothing was paid" do
      ids = tiles(1).map(&:id)
      post "/api/boards/#{board.id}/edit_images",
           params: { board_image_ids: ids, prompt: prompt }, headers: auth_headers(admin)

      expect(EditBoardImagesJob.jobs.last["args"][4]).to eq({})
    end
  end
end
