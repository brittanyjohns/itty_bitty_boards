require "rails_helper"

# Quick add lets a nonspeaking user drop a word onto a board from their own
# dashboard, so boards#add_image is the one board write a COMMUNICATOR token may
# make. Every other board write stays user-only.
#
# Two gates matter here and they answer different questions:
#   * check_communicator_board_access! — is this board on THIS communicator's
#     dashboard? (ownership)
#   * check_board_editable!            — is the owning user's plan letting them
#     edit it? (plan lock)
# `User#board_editable?` returns true for a board you don't own, so it can never
# stand in for the first one.
RSpec.describe "API::Boards quick add (communicator token)", type: :request do
  let(:owner) { create(:user) }
  let(:communicator) { create(:child_account, user: owner) }
  let(:board) { create(:board, user: owner, name: "Snack Time") }

  # A board that exists but is not on this communicator's dashboard.
  let(:unassigned_board) { create(:board, user: owner, name: "Not Theirs") }

  before { create(:child_board, board: board, child_account: communicator) }

  describe "a communicator adding to a board on their dashboard" do
    it "creates the tile and attributes the image to the owning user" do
      expect {
        post "/api/boards/#{board.id}/add_image",
             params: { image: { label: "pretzel" } },
             headers: auth_headers(communicator)
      }.to change(Image, :count).by(1)

      expect(response).to have_http_status(:ok)

      image = Image.order(:created_at).last
      expect(image.label).to eq("pretzel")
      # A ChildAccount owns no Images — everything belongs to the adult.
      expect(image.user_id).to eq(owner.id)
      expect(board.reload.images).to include(image)
    end

    it "keeps an explicit part_of_speech so a multi-word phrase is not re-categorized" do
      post "/api/boards/#{board.id}/add_image",
           params: { image: { label: "I want more please", part_of_speech: "phrase" } },
           headers: auth_headers(communicator)

      expect(response).to have_http_status(:ok)
      expect(Image.order(:created_at).last.part_of_speech).to eq("phrase")
    end
  end

  describe "a communicator adding to a board that is not theirs" do
    it "is refused, and writes nothing" do
      expect {
        post "/api/boards/#{unassigned_board.id}/add_image",
             params: { image: { label: "nope" } },
             headers: auth_headers(communicator)
      }.not_to change(Image, :count)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("board_not_available")
    end
  end

  describe "a communicator with no owning user" do
    let(:orphan) { create(:child_account, user: nil) }

    it "is refused rather than acting as nobody" do
      post "/api/boards/#{board.id}/add_image",
           params: { image: { label: "nope" } },
           headers: auth_headers(orphan)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  it "still refuses a request carrying no credential at all" do
    post "/api/boards/#{board.id}/add_image", params: { image: { label: "nope" } }

    expect(response).to have_http_status(:unauthorized)
  end

  describe "the existing user-token path" do
    it "is unchanged" do
      expect {
        post "/api/boards/#{board.id}/add_image",
             params: { image: { label: "apple" } },
             headers: auth_headers(owner)
      }.to change(Image, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(Image.order(:created_at).last.user_id).to eq(owner.id)
    end

    it "does not gain the communicator dashboard restriction" do
      post "/api/boards/#{unassigned_board.id}/add_image",
           params: { image: { label: "banana" } },
           headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
    end
  end

  # Assignment attaches the ROOT of a set; its folder pages carry no
  # child_boards row. The dashboard association therefore answers "what was
  # attached", never "what is this communicator looking at" — which is why the
  # gate reads Boards::QuickAddScope instead.
  describe "a communicator adding to a page inside a set on their dashboard" do
    let(:page) { create(:board, user: owner, name: "Food") }

    before { create(:board_image, board: board, predictive_board_id: page.id) }

    it "is allowed, even though the page has no child_boards row of its own" do
      expect(ChildBoard.where(board_id: page.id)).to be_empty

      expect {
        post "/api/boards/#{page.id}/add_image",
             params: { image: { label: "pretzel" } },
             headers: auth_headers(communicator)
      }.to change(Image, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(page.reload.images.map(&:label)).to include("pretzel")
    end
  end

  # Nobody is blocked for sharing. Boards on several dashboards are the normal
  # setup (siblings, a classroom set), and quick add exists so a nonspeaking
  # person can add a word when they need it.
  describe "a communicator adding to a board a sibling also uses" do
    let(:sibling) { create(:child_account, user: owner, name: "Maya") }

    before { create(:child_board, board: board, child_account: sibling) }

    it "is allowed" do
      post "/api/boards/#{board.id}/add_image",
           params: { image: { label: "pretzel" } },
           headers: auth_headers(communicator)

      expect(response).to have_http_status(:ok)
    end
  end

  # board_images permits predictive_board_id without validating the target and
  # board ids are sequential, so a folder tile can point anywhere. Reachability
  # must refuse to FOLLOW such a pointer rather than trust it.
  describe "a board reachable only through a tile aimed at another account" do
    let(:stranger) { create(:user) }
    let(:victim) { create(:board, user: stranger, name: "Someone Else's Board") }

    before { create(:board_image, board: board, predictive_board_id: victim.id) }

    it "is refused, and the other account's board gains no tile" do
      expect {
        post "/api/boards/#{victim.id}/add_image",
             params: { image: { label: "nope" } },
             headers: auth_headers(communicator)
      }.not_to change { victim.board_images.count }

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("board_not_available")
    end
  end

  # Assignment attaches the REAL admin-owned row, so a tile added here would
  # land on the board every account sees. The owner-or-admin gate already
  # refuses the parent; this makes the communicator match the adult.
  describe "an attached public library board" do
    let(:admin) { create(:admin_user) }
    let(:public_board) do
      create(:board, user: admin, name: "Core Words", predefined: true, published: true)
    end

    before { create(:child_board, board: public_board, child_account: communicator) }

    it "is refused rather than edited for everyone" do
      expect {
        post "/api/boards/#{public_board.id}/add_image",
             params: { image: { label: "nope" } },
             headers: auth_headers(communicator)
      }.not_to change { public_board.board_images.count }

      expect(response).to have_http_status(:forbidden)
    end
  end

  # The reason the picker and the gate read one object rather than two copies
  # of the same arithmetic: a board the picker offers can never 403, and a
  # board it withholds is always refused.
  describe "the picker and the gate" do
    it "agree on every board, in both directions" do
      page = create(:board, user: owner, name: "Food")
      deep = create(:board, user: owner, name: "Snacks")
      victim = create(:board, user: create(:user), name: "Someone Else's")
      create(:board_image, board: board, predictive_board_id: page.id)
      create(:board_image, board: page, predictive_board_id: deep.id)
      create(:board_image, board: board, predictive_board_id: victim.id)

      get "/api/account/quick_add_targets", headers: auth_headers(communicator)
      offered = JSON.parse(response.body)["boards"].map { |b| b["id"] }

      expect(offered).to contain_exactly(board.id, page.id, deep.id)

      offered.each do |board_id|
        post "/api/boards/#{board_id}/add_image",
             params: { image: { label: "word #{board_id}" } },
             headers: auth_headers(communicator)
        expect(response).to have_http_status(:ok), "expected #{board_id} to be writable"
      end

      [victim.id, unassigned_board.id].each do |board_id|
        post "/api/boards/#{board_id}/add_image",
             params: { image: { label: "nope" } },
             headers: auth_headers(communicator)
        expect(response).to have_http_status(:forbidden), "expected #{board_id} to be refused"
      end
    end
  end
end
