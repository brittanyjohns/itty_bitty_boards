require "rails_helper"

# GET /api/free_download_boards is PUBLIC (no auth) and returns the curated
# public board gallery (Board.public_boards — admin-owned, predefined +
# published), in the lean lead-capture contract shape.
RSpec.describe "API free_download_boards", type: :request do
  let(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) ||
      create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  def public_board(name, description: nil)
    create(:board, name: name, description: description,
                   user: admin, predefined: true, published: true)
  end

  let!(:free_board) { public_board("Free Starter", description: "A freebie") }
  let!(:other_free_board) { public_board("Another Freebie") }
  # Not in the public gallery (not published) — must not appear.
  let!(:gated_board) do
    create(:board, name: "Paid Only", user: admin, predefined: true, published: false)
  end

  it "returns only public gallery boards without auth" do
    get "/api/free_download_boards"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    names = body["boards"].map { |b| b["name"] }

    expect(names).to contain_exactly("Free Starter", "Another Freebie")
    expect(names).not_to include("Paid Only")
  end

  it "returns the contract shape (id, name, description, image_url)" do
    get "/api/free_download_boards"

    entry = JSON.parse(response.body)["boards"].find { |b| b["name"] == "Free Starter" }
    expect(entry.keys).to contain_exactly("id", "name", "description", "image_url")
    expect(entry["id"]).to eq(free_board.id)
    expect(entry["description"]).to eq("A freebie")
    expect(entry).to have_key("image_url")
  end
end
