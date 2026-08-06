require "rails_helper"

RSpec.describe "Admin::BoardPrintables (dashboard)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }
  let(:owner) { create(:user) }
  let!(:board) { create(:board, user: owner, name: "Core Words") }

  def link(from, to, position: 0)
    create(:board_image, board: from, predictive_board_id: to.id, position: position)
  end

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
  end

  describe "authorization" do
    it "redirects a non-admin away from every action" do
      sign_in create(:user)
      printable = BoardPrintable.create!(board: board, status: "pending", board_ids: [board.id])

      get admin_dashboard_board_printables_path
      expect(response).to redirect_to(root_path)

      get admin_dashboard_board_printable_path(printable)
      expect(response).to redirect_to(root_path)
    end

    it "redirects a signed-out visitor" do
      get admin_dashboard_board_printables_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "GET /admin/board_printables" do
    it "lists recent printables" do
      sign_in admin
      BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id], created_by: admin)

      get admin_dashboard_board_printables_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Core Words")
      expect(response.body).to include("complete")
    end

    it "searches boards by name" do
      sign_in admin

      get admin_dashboard_board_printables_path(board_search: "Core")

      expect(response.body).to include("Core Words")
    end

    it "searches boards by id" do
      sign_in admin

      get admin_dashboard_board_printables_path(board_search: board.id.to_s)

      expect(response.body).to include("Core Words")
    end
  end

  describe "GET /admin/board_printables/:id" do
    it "shows a pending printable with an auto-refresh meta tag" do
      sign_in admin
      printable = BoardPrintable.create!(board: board, status: "pending", board_ids: [board.id])

      get admin_dashboard_board_printable_path(printable)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('http-equiv="refresh"')
    end

    it "shows download links for a complete printable" do
      sign_in admin
      printable = BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id])
      allow(printable).to receive(:files_view).and_return([
        { variant: "full", filename: "core-words.pdf", url: "https://cdn.example.com/core-words.pdf", byte_size: 12_345 },
      ])
      allow(BoardPrintable).to receive(:find).and_return(printable)

      get admin_dashboard_board_printable_path(printable)

      expect(response.body).to include("https://cdn.example.com/core-words.pdf")
      expect(response.body).not_to include('http-equiv="refresh"')
    end

    it "shows the error message for a failed printable" do
      sign_in admin
      printable = BoardPrintable.create!(board: board, status: "failed", board_ids: [board.id], error_message: "Grover timed out")

      get admin_dashboard_board_printable_path(printable)

      expect(response.body).to include("Grover timed out")
    end
  end

  describe "POST /admin/board_printables" do
    it "creates a pending record and enqueues the job" do
      sign_in admin

      expect {
        post admin_dashboard_board_printables_path,
          params: { board_id: board.id, include_subboards: "1", max_boards: "10", topic: "mealtime" }
      }.to change(GenerateBoardPrintableJob.jobs, :size).by(1)

      printable = BoardPrintable.last
      expect(printable.board).to eq(board)
      expect(printable.created_by).to eq(admin)
      expect(printable.include_subboards).to be(true)
      expect(printable.max_boards).to eq(10)
      expect(printable.topic).to eq("mealtime")
      expect(response).to redirect_to(admin_dashboard_board_printable_path(printable))
    end

    it "defaults to a single board with the standard cap when no options are given" do
      sign_in admin

      post admin_dashboard_board_printables_path, params: { board_id: board.id }

      printable = BoardPrintable.last
      expect(printable.include_subboards).to be(false)
      expect(printable.max_boards).to eq(BoardPrintable::DEFAULT_MAX_BOARDS)
      expect(printable.board_ids).to eq([board.id])
    end

    it "records the walked tree in BFS order when subboards are included" do
      sign_in admin
      child = create(:board, user: owner)
      link(board, child)

      post admin_dashboard_board_printables_path, params: { board_id: board.id, include_subboards: "1" }

      expect(BoardPrintable.last.board_ids).to eq([board.id, child.id])
    end

    it "clamps an absurd max_boards to the ceiling rather than trusting it" do
      sign_in admin

      post admin_dashboard_board_printables_path, params: { board_id: board.id, max_boards: "100000" }

      expect(BoardPrintable.last.max_boards).to eq(BoardPrintable::MAX_BOARDS_CEILING)
    end

    it "alerts without creating a record when the board doesn't exist" do
      sign_in admin

      expect {
        post admin_dashboard_board_printables_path, params: { board_id: -1 }
      }.not_to change(BoardPrintable, :count)

      expect(response).to redirect_to(admin_dashboard_board_printables_path)
    end

    it "alerts when the tree exceeds max_boards rather than creating a partial record" do
      sign_in admin
      child = create(:board, user: owner)
      link(board, child)

      expect {
        post admin_dashboard_board_printables_path, params: { board_id: board.id, include_subboards: "1", max_boards: "1" }
      }.not_to change(BoardPrintable, :count)

      expect(response).to redirect_to(admin_dashboard_board_printables_path)
      # Exact wording belongs to Boards::Printables::CollectPages, not this controller.
      expect(flash[:alert]).to be_present
    end

    context "when signed in as non-admin" do
      it "redirects to root and does not create a printable" do
        sign_in create(:user)

        expect {
          post admin_dashboard_board_printables_path, params: { board_id: board.id }
        }.not_to change(BoardPrintable, :count)

        expect(response).to redirect_to(root_path)
      end
    end
  end
end
