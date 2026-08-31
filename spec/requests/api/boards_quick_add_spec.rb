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
end
