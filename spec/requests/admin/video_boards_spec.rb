require "rails_helper"

RSpec.describe "Admin::VideoBoards (dashboard)", type: :request do
  include Devise::Test::IntegrationHelpers

  let!(:seed_admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }
  let(:admin) { create(:admin_user) }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
  end

  def create_params(overrides = {})
    {
      name: "Nursery Rhymes",
      description: "Sing-along videos",
      tags: "videos, songs",
      columns: "3",
      videos: {
        "0" => { label: "Baby Shark", url: "https://www.youtube.com/watch?v=XqZsoesa55w", start_seconds: "", end_seconds: "" },
        "1" => { label: "BINGO", url: "https://youtu.be/9mmF8zOlh_g", start_seconds: "", end_seconds: "" },
      },
    }.merge(overrides)
  end

  def seeded_board(attrs = {})
    VideoBoards::BoardSeeder.build_board!(
      { name: "Existing Videos", description: "", tags: [], columns: 2,
        settings: { "video_seeder" => true },
        videos: [{ label: "more", youtube_id: "34CBy8zipZQ", range: {} }] }.merge(attrs),
      admin: seed_admin,
    )
  end

  describe "authorization" do
    it "redirects a non-admin away from every action" do
      sign_in create(:user)
      board = seeded_board

      get admin_dashboard_video_boards_path
      expect(response).to redirect_to(root_path)

      get new_admin_dashboard_video_board_path
      expect(response).to redirect_to(root_path)

      post admin_dashboard_video_boards_path, params: create_params
      expect(response).to redirect_to(root_path)
      expect(Board.where(name: "Nursery Rhymes")).to be_empty

      post publish_admin_dashboard_video_board_path(board)
      expect(response).to redirect_to(root_path)
      expect(board.reload.published).to be(false)
    end
  end

  describe "GET /admin/video_boards" do
    it "lists seeded boards only" do
      seeded_board
      create(:board, name: "Unrelated Board")
      sign_in admin

      get admin_dashboard_video_boards_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Existing Videos")
      expect(response.body).not_to include("Unrelated Board")
    end
  end

  describe "POST /admin/video_boards" do
    before { sign_in admin }

    it "creates an unpublished board with one video tile per row" do
      expect { post admin_dashboard_video_boards_path, params: create_params }
        .to change(Board, :count).by(1)

      board = Board.find_by(name: "Nursery Rhymes")
      expect(board.published).to be(false)
      expect(board.predefined).to be(true)
      expect(board.user_id).to eq(seed_admin.id)
      expect(board.settings["video_seeder"]).to be(true)
      expect(board.tags).to eq(%w[videos songs])
      expect(board.number_of_columns).to eq(3)

      ids = board.board_images.map { |bi| bi.data.dig("video", "youtube_id") }
      expect(ids).to contain_exactly("XqZsoesa55w", "9mmF8zOlh_g")
      expect(response).to redirect_to(admin_dashboard_video_board_path(board))
    end

    it "stores the trim range for a row with start and end seconds" do
      params = create_params
      params[:videos]["0"] = params[:videos]["0"].merge(start_seconds: "45", end_seconds: "72")
      post admin_dashboard_video_boards_path, params: params

      tile = Board.find_by(name: "Nursery Rhymes").board_images
                  .find { |bi| bi.data.dig("video", "youtube_id") == "XqZsoesa55w" }
      expect(tile.data["video"]["start_seconds"]).to eq(45)
      expect(tile.data["video"]["end_seconds"]).to eq(72)
    end

    it "accepts a start with a blank end" do
      params = create_params
      params[:videos]["0"] = params[:videos]["0"].merge(start_seconds: "30", end_seconds: "")
      post admin_dashboard_video_boards_path, params: params

      tile = Board.find_by(name: "Nursery Rhymes").board_images
                  .find { |bi| bi.data.dig("video", "youtube_id") == "XqZsoesa55w" }
      expect(tile.data["video"]["start_seconds"]).to eq(30)
      expect(tile.data["video"]).not_to have_key("end_seconds")
    end

    it "ignores fully blank rows" do
      params = create_params
      params[:videos]["2"] = { label: "", url: "", start_seconds: "", end_seconds: "" }
      post admin_dashboard_video_boards_path, params: params

      expect(Board.find_by(name: "Nursery Rhymes").board_images.count).to eq(2)
    end

    it "suggests a column count when none is given" do
      post admin_dashboard_video_boards_path, params: create_params(columns: "")
      expect(Board.find_by(name: "Nursery Rhymes").number_of_columns).to eq(2)
    end

    context "rejections" do
      it "rejects end <= start and writes nothing" do
        params = create_params
        params[:videos]["0"] = params[:videos]["0"].merge(start_seconds: "72", end_seconds: "45")

        expect { post admin_dashboard_video_boards_path, params: params }.not_to change(Board, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("end must be after start")
      end

      it "rejects non-numeric seconds" do
        params = create_params
        params[:videos]["0"] = params[:videos]["0"].merge(start_seconds: "1.5", end_seconds: "")

        expect { post admin_dashboard_video_boards_path, params: params }.not_to change(Board, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "rejects a malformed URL and preserves the submitted values" do
        params = create_params
        params[:videos]["1"] = params[:videos]["1"].merge(url: "https://vimeo.com/12345")

        expect { post admin_dashboard_video_boards_path, params: params }.not_to change(Board, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("isn&#39;t a recognizable YouTube video URL")
        expect(response.body).to include("Nursery Rhymes")
        expect(response.body).to include("https://vimeo.com/12345")
      end

      it "rejects a row with a URL but no label" do
        params = create_params
        params[:videos]["1"] = params[:videos]["1"].merge(label: "")

        expect { post admin_dashboard_video_boards_path, params: params }.not_to change(Board, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "rejects a submission with zero usable rows" do
        params = create_params(videos: { "0" => { label: "", url: "", start_seconds: "", end_seconds: "" } })

        expect { post admin_dashboard_video_boards_path, params: params }.not_to change(Board, :count)
        expect(response.body).to include("Add at least one video row")
      end

      it "rejects a blank name" do
        expect { post admin_dashboard_video_boards_path, params: create_params(name: "") }
          .not_to change(Board, :count)
        expect(response.body).to include("Give the board a name")
      end

      it "rejects a duplicate board name" do
        seeded_board

        expect { post admin_dashboard_video_boards_path, params: create_params(name: "Existing Videos") }
          .not_to change(Board, :count)
        expect(response.body).to include("already exists")
      end
    end
  end

  describe "publish / unpublish" do
    before { sign_in admin }

    it "publishes a board that has tiles" do
      board = seeded_board
      post publish_admin_dashboard_video_board_path(board)

      expect(board.reload.published).to be(true)
      expect(response).to redirect_to(admin_dashboard_video_board_path(board))
    end

    it "refuses to publish an empty board" do
      board = seeded_board(videos: [])
      expect(board.board_images).to be_empty

      post publish_admin_dashboard_video_board_path(board)

      expect(board.reload.published).to be(false)
      expect(flash[:alert]).to include("no tiles")
    end

    it "unpublishes a published board" do
      board = seeded_board
      board.update!(published: true)

      post unpublish_admin_dashboard_video_board_path(board)
      expect(board.reload.published).to be(false)
    end

    it "does not reach a board that wasn't created here" do
      other = create(:board, name: "Not A Video Board")
      post publish_admin_dashboard_video_board_path(other)

      expect(response).to redirect_to(admin_dashboard_video_boards_path)
      expect(other.reload.published).to be_falsey
    end
  end

  describe "DELETE /admin/video_boards/:id" do
    before { sign_in admin }

    it "deletes an unpublished board" do
      board = seeded_board
      expect { delete admin_dashboard_video_board_path(board) }.to change(Board, :count).by(-1)
      expect(response).to redirect_to(admin_dashboard_video_boards_path)
    end

    it "refuses to delete a published board" do
      board = seeded_board
      board.update!(published: true)

      expect { delete admin_dashboard_video_board_path(board) }.not_to change(Board, :count)
      expect(flash[:alert]).to include("unpublish")
    end
  end

  describe "GET /admin/video_boards/:id" do
    it "shows a watchable link and the trim range for each tile" do
      board = seeded_board(videos: [{ label: "more", youtube_id: "34CBy8zipZQ",
                                      range: { "start_seconds" => 5, "end_seconds" => 20 } }])
      sign_in admin

      get admin_dashboard_video_board_path(board)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("https://www.youtube.com/watch?v=34CBy8zipZQ")
      expect(response.body).to include("5s")
      expect(response.body).to include("20")
    end
  end
end
