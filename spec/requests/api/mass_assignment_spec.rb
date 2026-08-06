require "rails_helper"

# Regression coverage for #27 — strong-params permit lists must not let a client
# mass-assign ownership fields. The owner of a created/updated record is always
# derived server-side from the authenticated user, never from request params.
RSpec.describe "Mass-assignment of ownership fields", type: :request do
  let(:owner)    { create(:user) }
  let(:attacker) { create(:user) }

  describe "POST /api/child_accounts" do
    it "ignores a client-supplied user_id and owns the communicator to the caller" do
      post "/api/child_accounts",
           params: { name: "Sam", username: "sam-#{SecureRandom.hex(2)}", user_id: attacker.id },
           headers: auth_headers(owner)

      expect(response).to have_http_status(:created)
      child = ChildAccount.order(:id).last
      expect(child.owner_id).to eq(owner.id)
      expect(child.owner_id).not_to eq(attacker.id)
      expect(child.user_id).to eq(owner.id)
    end
  end

  # #27 — `predefined` decides whether a board is offered as a starter board and
  # is one of the three conditions for `Board.public_boards` (the curated
  # gallery), so a non-admin must not be able to self-promote via update.
  #
  # #633 — `published` is deliberately NOT in that category. On a user-owned
  # board it only controls `Board#viewable_by?`, i.e. whether the owner's own
  # /pb/<slug> share link opens for a visitor. Owners set it themselves.
  describe "PATCH /api/boards/:id (predefined/published)" do
    let(:board) { create(:board, user: owner, predefined: false, published: false) }

    it "ignores predefined from a non-admin owner but honours published" do
      patch "/api/boards/#{board.id}",
            params: { board: { predefined: true, published: true } },
            headers: auth_headers(owner)

      board.reload
      expect(board.predefined).to be_falsey
      expect(board.published).to be true
    end

    it "lets a non-admin owner unpublish their own board again" do
      board.update!(published: true)

      patch "/api/boards/#{board.id}",
            params: { board: { published: false } },
            headers: auth_headers(owner)

      expect(board.reload.published).to be false
    end

    it "does not put a self-published user board into the curated gallery" do
      patch "/api/boards/#{board.id}",
            params: { board: { published: true } },
            headers: auth_headers(owner)

      expect(board.reload.published).to be true
      expect(Board.public_boards).not_to include(board)
    end

    it "does not let a non-owner publish someone else's board" do
      patch "/api/boards/#{board.id}",
            params: { board: { published: true } },
            headers: auth_headers(attacker)

      expect(response).to have_http_status(:unauthorized)
      expect(board.reload.published).to be_falsey
    end

    it "still lets an admin curate predefined/published" do
      admin = create(:admin_user)
      admin_board = create(:board, user: admin, predefined: false, published: false)

      patch "/api/boards/#{admin_board.id}",
            params: { board: { predefined: true, published: true } },
            headers: auth_headers(admin)

      admin_board.reload
      expect(admin_board.predefined).to be true
      expect(admin_board.published).to be true
    end
  end

  # #27 — same rule for menus: a non-admin can't flip `predefined`.
  describe "PATCH /api/menus/:id (predefined self-promotion)" do
    it "ignores predefined from a non-admin owner" do
      menu = Menu.create!(user: owner, name: "My Menu", predefined: false)

      patch "/api/menus/#{menu.id}",
            params: { menu: { name: "Renamed", predefined: true } },
            headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      menu.reload
      expect(menu.predefined).to be_falsey
      expect(menu.name).to eq("Renamed")
    end
  end
end
