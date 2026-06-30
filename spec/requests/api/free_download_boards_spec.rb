require "rails_helper"

# GET /api/free_download_boards is PUBLIC (no auth) and returns only the boards
# flagged free_download_enabled, in the lean lead-capture contract shape.
RSpec.describe "API free_download_boards", type: :request do
  let!(:free_board) do
    create(:board, name: "Free Starter", description: "A freebie", free_download_enabled: true)
  end
  let!(:other_free_board) do
    create(:board, name: "Another Freebie", free_download_enabled: true)
  end
  let!(:gated_board) do
    create(:board, name: "Paid Only", free_download_enabled: false)
  end

  it "returns only free_download_enabled boards without auth" do
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
