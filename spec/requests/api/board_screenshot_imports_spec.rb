require "rails_helper"

# Covers the screenshot-import controller correctness fixes:
# - create: image required, credit spend + txn stashed for refund, columns sanitized
# - update: tolerant of a missing board_screenshot key, persists name and
#   row/col edits, recomputes rows, and leaves a committed import committed
# - commit: guarded against committing an import that isn't ready
RSpec.describe "API::BoardScreenshotImports", type: :request do
  let(:user)  { FactoryBot.create(:user) }
  let(:other) { FactoryBot.create(:user) }

  # 1x1 transparent PNG as a data URL (the controller only attaches it).
  let(:data_url) do
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
  end

  describe "POST /api/board_screenshot_imports (create)" do
    # The initial credit grant is deferred to email verification (task-2b),
    # so a bare `create(:user)` now starts at 0 credits. Grant explicitly —
    # these specs are about the screenshot-import spend flow, not the grant
    # path itself. The "out of credits" spec below overrides this back to 0.
    before do
      CreditService.grant_plan!(user, amount: 100, period_end: 1.month.from_now,
                                       metadata: { source: "spec" })
    end

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

    # The review screen's Name field is what BoardFromScreenshot uses to name
    # the board it builds. It was permitted but never assigned, so typing a
    # name and saving silently did nothing.
    it "persists the name" do
      patch "/api/board_screenshot_imports/#{import.id}",
            params: { board_screenshot: { name: "  Morning time  " } },
            headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(import.reload.name).to eq("Morning time")
    end

    it "leaves the existing name alone when none is sent" do
      import.update!(name: "Kept")
      patch "/api/board_screenshot_imports/#{import.id}",
            params: { board_screenshot: { cols: 3 } },
            headers: auth_headers(user)

      expect(import.reload.name).to eq("Kept")
    end

    # Rows aren't editable in the UI — they follow from where the cells landed.
    it "recomputes guessed_rows from the cells' positions" do
      import.update!(guessed_rows: 1)
      import.board_screenshot_cells.create!(row: 0, col: 1, label_norm: "b", bg_color: "white")

      patch "/api/board_screenshot_imports/#{import.id}",
            params: { board_screenshot: { cells: [{ id: cell.id, row: 3, col: 0 }] } },
            headers: auth_headers(user)

      expect(import.reload.guessed_rows).to eq(4)
    end

    it "keeps guessed_rows when the import has no cells" do
      empty = user.board_screenshot_imports.create!(status: "needs_review", guessed_rows: 5)
      patch "/api/board_screenshot_imports/#{empty.id}",
            params: { board_screenshot: { cols: 2 } }, headers: auth_headers(user)

      expect(empty.reload.guessed_rows).to eq(5)
    end

    # A committed import already has a board. Knocking it back to needs_review
    # on a label edit loses the only record that it shipped.
    it "does not move a committed import back to needs_review" do
      import.update!(status: "committed")
      patch "/api/board_screenshot_imports/#{import.id}",
            params: { board_screenshot: { name: "Renamed" } },
            headers: auth_headers(user)

      expect(import.reload.status).to eq("committed")
      expect(import.name).to eq("Renamed")
    end

    it "returns the updated record so the client can render it" do
      patch "/api/board_screenshot_imports/#{import.id}",
            params: { board_screenshot: { name: "Snack time" } },
            headers: auth_headers(user)

      body = JSON.parse(response.body)
      expect(body["name"]).to eq("Snack time")
      expect(body["cells"].length).to eq(1)
    end

    it "refuses to touch another user's import" do
      import.update!(name: "Mine")
      patch "/api/board_screenshot_imports/#{import.id}",
            params: { board_screenshot: { name: "Nope" } },
            headers: auth_headers(other)

      expect(response).not_to have_http_status(:ok)
      expect(import.reload.name).to eq("Mine")
    end
  end

  describe "GET /api/board_screenshot_imports/:id (show)" do
    # The review screen is the only place a user meets a failed import, so
    # without this it could only say "something went wrong".
    it "exposes error_message so a failed import can explain itself" do
      import = user.board_screenshot_imports.create!(status: "failed", error_message: "no grid found")
      get "/api/board_screenshot_imports/#{import.id}", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["error_message"]).to eq("no grid found")
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
