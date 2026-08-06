require "rails_helper"

RSpec.describe "API::Admin::BoardPrintables", type: :request do
  let(:admin) { create(:admin_user) }
  let(:owner) { create(:user) }
  let!(:board) { create(:board, user: owner, name: "Core Words", slug: "core-words") }

  def link(from, to, position: 0)
    create(:board_image, board: from, predictive_board_id: to.id, position: position)
  end

  def json = JSON.parse(response.body)

  describe "POST /api/admin/boards/:board_id/printables" do
    it "creates a pending record and enqueues the job" do
      expect {
        post "/api/admin/boards/#{board.id}/printables",
          params: { include_subboards: true, max_boards: 10, topic: "mealtime" },
          headers: auth_headers(admin)
      }.to change(GenerateBoardPrintableJob.jobs, :size).by(1)

      expect(response).to have_http_status(:accepted)
      expect(json["status"]).to eq("pending")
      expect(json["board_id"]).to eq(board.id)
      expect(json["include_subboards"]).to be(true)
      expect(json["files"]).to eq([])

      printable = BoardPrintable.find(json["id"])
      expect(printable.created_by).to eq(admin)
      expect(printable.max_boards).to eq(10)
      expect(printable.topic).to eq("mealtime")
      expect(printable.board_ids).to eq([board.id])
    end

    it "defaults to a single board with the standard cap" do
      post "/api/admin/boards/#{board.id}/printables", headers: auth_headers(admin)

      printable = BoardPrintable.find(json["id"])
      expect(printable.include_subboards).to be(false)
      expect(printable.max_boards).to eq(BoardPrintable::DEFAULT_MAX_BOARDS)
      expect(printable.topic).to be_nil
    end

    it "records the walked tree in BFS order when subboards are included" do
      child = create(:board, user: owner)
      link(board, child)

      post "/api/admin/boards/#{board.id}/printables",
        params: { include_subboards: true }, headers: auth_headers(admin)

      expect(BoardPrintable.find(json["id"]).board_ids).to eq([board.id, child.id])
    end

    it "clamps an absurd max_boards to the ceiling rather than trusting it" do
      post "/api/admin/boards/#{board.id}/printables",
        params: { include_subboards: true, max_boards: 100_000 }, headers: auth_headers(admin)

      expect(BoardPrintable.find(json["id"]).max_boards)
        .to eq(BoardPrintable::MAX_BOARDS_CEILING)
    end

    it "404s for a board that doesn't exist" do
      post "/api/admin/boards/0/printables", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
      expect(BoardPrintable.count).to eq(0)
    end

    # Admin is global by design: a printable can be generated from any board,
    # not just the admin's own. Asserted deliberately so the intent is recorded.
    it "allows an admin to generate from a board owned by someone else" do
      expect(board.user).not_to eq(admin)

      post "/api/admin/boards/#{board.id}/printables", headers: auth_headers(admin)

      expect(response).to have_http_status(:accepted)
    end

    describe "when the subboard tree is over the cap" do
      before { 3.times { |i| link(board, create(:board, user: owner), position: i) } }

      it "422s, creates nothing, and enqueues nothing" do
        expect {
          post "/api/admin/boards/#{board.id}/printables",
            params: { include_subboards: true, max_boards: 2 }, headers: auth_headers(admin)
        }.not_to change(GenerateBoardPrintableJob.jobs, :size)

        expect(response).to have_http_status(:unprocessable_content)
        expect(json["error"]).to match(/more than 2 boards/)
        # Nothing left half-created in "generating" for a poller to sit on.
        expect(BoardPrintable.count).to eq(0)
      end

      it "still succeeds with subboards off, since the cap only bounds the walk" do
        post "/api/admin/boards/#{board.id}/printables",
          params: { include_subboards: false, max_boards: 2 }, headers: auth_headers(admin)

        expect(response).to have_http_status(:accepted)
      end
    end
  end

  describe "GET /api/admin/board_printables/:id" do
    let(:printable) { BoardPrintable.create!(board: board, created_by: admin, status: "generating") }

    it "returns the current status for polling" do
      get "/api/admin/board_printables/#{printable.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(json["status"]).to eq("generating")
      expect(json["files"]).to eq([])
    end

    it "surfaces the failure message once the job has failed" do
      printable.mark_failed!("Chrome crashed")

      get "/api/admin/board_printables/#{printable.id}", headers: auth_headers(admin)

      expect(json["status"]).to eq("failed")
      expect(json["error_message"]).to eq("Chrome crashed")
    end

    it "404s for an id that doesn't exist" do
      get "/api/admin/board_printables/0", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/admin/board_printables/:id/download_url" do
    let(:printable) { BoardPrintable.create!(board: board, created_by: admin, status: "pending") }

    def attach_both_variants
      printable.attach_pdf!(
        filename: "core-words.color.pdf", bytes: "%PDF-1.5 colour",
        variant: BoardPrintable::VARIANT_COLOR,
      )
      printable.attach_pdf!(
        filename: "core-words.low-ink.pdf", bytes: "%PDF-1.5 low ink",
        variant: BoardPrintable::VARIANT_LOW_INK,
      )
      printable.update!(status: "complete")
    end

    it "returns one entry per file, labelled by variant" do
      attach_both_variants

      get "/api/admin/board_printables/#{printable.id}/download_url", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      files = json["files"].sort_by { |f| f["variant"] }
      expect(files.map { |f| f["variant"] }).to eq(["color", "low_ink"])
      expect(files.map { |f| f["filename"] })
        .to eq(["core-words.color.pdf", "core-words.low-ink.pdf"])
      expect(files.map { |f| f["url"] }).to all(be_present)
    end

    it "404s while the job is still running" do
      get "/api/admin/board_printables/#{printable.id}/download_url", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "404s when the record says complete but nothing is attached" do
      printable.update!(status: "complete")

      get "/api/admin/board_printables/#{printable.id}/download_url", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end
  end

  # The frontend deliberately ships no client-side admin guard, so this 401 is
  # the only real gate on the feature.
  describe "authorization" do
    let(:printable) { BoardPrintable.create!(board: board, created_by: admin, status: "pending") }

    it "401s a create with no token" do
      expect {
        post "/api/admin/boards/#{board.id}/printables"
      }.not_to change(BoardPrintable, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "401s a create from a signed-in non-admin" do
      expect {
        post "/api/admin/boards/#{board.id}/printables", headers: auth_headers(owner)
      }.not_to change(BoardPrintable, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it "401s a status poll from a signed-in non-admin" do
      get "/api/admin/board_printables/#{printable.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:unauthorized)
    end

    it "401s a download_url from a signed-in non-admin" do
      get "/api/admin/board_printables/#{printable.id}/download_url", headers: auth_headers(owner)

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
