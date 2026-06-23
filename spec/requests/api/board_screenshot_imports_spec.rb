require "rails_helper"

# Covers the screenshot-import controller correctness fixes:
# - create: image required, credit spend + txn stashed for refund, columns sanitized
# - update: tolerant of a missing board_screenshot key, persists row/col edits
# - commit: guarded against committing an import that isn't ready
RSpec.describe "API::BoardScreenshotImports", type: :request do
  let(:user)  { FactoryBot.create(:user) }
  let(:other) { FactoryBot.create(:user) }

  # 1x1 transparent PNG as a data URL (the controller only attaches it).
  let(:data_url) do
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
  end

  describe "POST /api/board_screenshot_imports (create)" do
    it "rejects anonymous callers with 401" do
      post "/api/board_screenshot_imports", params: { cropped_image: data_url }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 422 when no image is provided" do
      post "/api/board_screenshot_imports", params: { name: "x" }, headers: auth_headers(user)
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/no image/i)
    end

    it "creates the import, spends credits, stashes the txn id, and enqueues the job" do
      expect(BoardScreenshotImportJob).to receive(:perform_async)

      expect {
        post "/api/board_screenshot_imports",
             params: { name: "Kitchen", columns: "6", cropped_image: data_url },
             headers: auth_headers(user)
      }.to change { user.reload.plan_credits_balance }.by(-CreditService.cost_for("screenshot_import"))

      expect(response).to have_http_status(:ok)
      import = user.board_screenshot_imports.last
      expect(import.metadata["credit_txn_id"]).to be_present
      expect(CreditTransaction.find(import.metadata["credit_txn_id"]).kind).to eq("spend")
    end

    it "sanitizes a non-positive columns value to auto-detect (nil)" do
      expect(BoardScreenshotImportJob).to receive(:perform_async) do |_id, columns|
        expect(columns).to be_nil
      end
      post "/api/board_screenshot_imports",
           params: { columns: "0", cropped_image: data_url },
           headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
    end

    it "returns 402 and does not enqueue when the user is out of credits" do
      user.update_columns(plan_credits_balance: 0, topup_credits_balance: 0)
      expect(BoardScreenshotImportJob).not_to receive(:perform_async)

      post "/api/board_screenshot_imports",
           params: { cropped_image: data_url }, headers: auth_headers(user)

      expect(response).to have_http_status(402)
      expect(JSON.parse(response.body)["error"]).to eq("insufficient_credits")
    end
  end

  describe "PATCH /api/board_screenshot_imports/:id (update)" do
    let(:import) { user.board_screenshot_imports.create!(status: "needs_review") }
    let!(:cell)  { import.board_screenshot_cells.create!(row: 0, col: 0, label_norm: "old", bg_color: "white") }

    it "persists label, color, row and col edits via the board_screenshot key" do
      patch "/api/board_screenshot_imports/#{import.id}",
            params: { board_screenshot: { cols: 4, cells: [{ id: cell.id, label_norm: "eat", bg_color: "#FF7070", row: 1, col: 2 }] } },
            headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      cell.reload
      expect(cell.label_norm).to eq("eat")
      expect(cell.bg_color).to eq("#FF7070")
      expect(cell.row).to eq(1)
      expect(cell.col).to eq(2)
      expect(import.reload.guessed_cols).to eq(4)
    end

    it "does not 500 when the board_screenshot key is absent" do
      patch "/api/board_screenshot_imports/#{import.id}", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(import.reload.status).to eq("needs_review")
    end
  end

  describe "POST /api/board_screenshot_imports/:id/commit" do
    it "returns 422 when the import is not ready (still processing)" do
      import = user.board_screenshot_imports.create!(status: "processing")
      post "/api/board_screenshot_imports/#{import.id}/commit", headers: auth_headers(user)
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("import_not_ready")
    end

    it "builds a board when the import is ready" do
      import = user.board_screenshot_imports.create!(status: "needs_review", guessed_cols: 2)
      import.board_screenshot_cells.create!(row: 0, col: 0, label_norm: "hi", bg_color: "white")

      expect {
        post "/api/board_screenshot_imports/#{import.id}/commit", headers: auth_headers(user)
      }.to change { user.boards.count }.by(1)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["ok"]).to be(true)
      expect(body["board_id"]).to be_present
    end
  end
end
