require "rails_helper"

# A board's `parent` records PROVENANCE — the Menu it was extracted from, the
# Image behind a predictive board, the Board that spawned a subboard. Every
# board save used to reassign it to the owning User, which permanently severed
# that link: the first rename or color change on a menu board dropped
# `original_menu_image_url` (the "View Menu" button on the board page),
# `menu_description`, and turned `menu_id` into the OWNER'S user id.
#
# Nothing else on the row points back at the Menu, so this was unrecoverable
# without a name-match backfill (`rake menu_boards:relink`).
RSpec.describe "API::Boards parent preservation", type: :request do
  let(:user) { create(:user) }

  def update_board(board, params)
    put "/api/boards/#{board.id}", params: params, headers: auth_headers(user)
  end

  describe "a board created from a menu" do
    let(:menu) { create(:menu, user: user, name: "Applebees", description: "Dinner menu") }
    let(:board) do
      create(:board, user: user, name: "Applebees", board_type: "menu",
                     parent_type: "Menu", parent_id: menu.id)
    end

    before do
      menu.menu_image.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/sample.png")),
        filename: "menu.png",
        content_type: "image/png",
      )
    end

    it "keeps the Menu parent through an ordinary rename" do
      update_board(board, board: { name: "Applebees Dinner" })

      expect(response).to have_http_status(:ok)
      board.reload
      expect(board.name).to eq("Applebees Dinner")
      expect(board.parent_type).to eq("Menu")
      expect(board.parent_id).to eq(menu.id)
    end

    it "still serves the menu photo and description after a save" do
      update_board(board, board: { name: "Applebees Dinner" })

      get "/api/boards/#{board.reload.id}", headers: auth_headers(user)
      body = JSON.parse(response.body)

      expect(body["original_menu_image_url"]).to be_present
      expect(body["menu_description"]).to eq("Dinner menu")
      expect(body["menu_id"]).to eq(menu.id)
    end

    it "reports menu_id from the Menu association, never the owner's user id" do
      # The old derivation was `board_type == "menu" ? parent_id : nil`, so a
      # severed board handed the frontend a User id labelled as a menu id.
      board.update_columns(parent_type: "User", parent_id: user.id)

      get "/api/boards/#{board.id}", headers: auth_headers(user)
      body = JSON.parse(response.body)

      expect(body["menu_id"]).to be_nil
      expect(body["menu_id"]).not_to eq(user.id)
    end
  end

  describe "other provenance parents" do
    it "keeps an Image parent (predictive/category boards)" do
      image = create(:image, user_id: user.id)
      board = create(:board, user: user, board_type: "predictive",
                             parent_type: "Image", parent_id: image.id)

      update_board(board, board: { name: "Renamed" })

      expect(board.reload.parent_type).to eq("Image")
      expect(board.parent_id).to eq(image.id)
    end

    it "keeps a Board parent (subboards spawned from a tile)" do
      parent_board = create(:board, user: user)
      board = create(:board, user: user, parent_type: "Board", parent_id: parent_board.id)

      update_board(board, board: { name: "Renamed" })

      expect(board.reload.parent_type).to eq("Board")
      expect(board.parent_id).to eq(parent_board.id)
    end
  end

  describe "a User-parented board" do
    it "still points the parent at the owner" do
      board = create(:board, user: user, parent_type: "User", parent_id: user.id)

      update_board(board, board: { name: "Renamed" })

      expect(board.reload.parent_type).to eq("User")
      expect(board.parent_id).to eq(user.id)
    end

  end

  # Both parent columns are NOT NULL, so a blank parent only exists on a record
  # that hasn't been saved yet — the case Board#set_parent covers on create.
  describe "Board#sync_user_parent" do
    it "fills in a blank parent on an unsaved board" do
      board = Board.new(user: user, name: "Fresh")

      board.sync_user_parent

      expect(board.parent_type).to eq("User")
      expect(board.parent_id).to eq(user.id)
    end

    it "prefers the explicit owner id over the board's user_id" do
      new_owner = create(:user)
      board = create(:board, user: user, parent_type: "User", parent_id: user.id)

      board.sync_user_parent(new_owner.id)

      expect(board.parent_id).to eq(new_owner.id)
    end

    it "ignores the explicit owner id when the parent is provenance" do
      menu = create(:menu, user: user)
      board = create(:board, user: user, parent_type: "Menu", parent_id: menu.id)

      board.sync_user_parent(create(:user).id)

      expect(board.parent_type).to eq("Menu")
      expect(board.parent_id).to eq(menu.id)
    end
  end
end
