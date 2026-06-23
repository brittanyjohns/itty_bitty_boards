require "rails_helper"

# GET /api/public_boards?myspeak=true feeds the MySpeak onboarding board
# picker. The board tagged "myspeak-recommended" (the "Core Words" starter)
# must surface first, ahead of the otherwise-alphabetical list.
RSpec.describe "API public_boards myspeak ordering", type: :request do
  # public_boards scopes to User::DEFAULT_ADMIN_ID, so the admin must own that id.
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  def myspeak_board(name, tags)
    create(:board, user: admin, name: name, predefined: true, published: true, tags: tags)
  end

  # Alphabetically these sort Animals, Basics, Core Words. The recommended tag
  # must pull Core Words to the front despite the alphabetical names ahead of it.
  # Three boards keeps the scope above the < 3 public_boards fallback.
  let!(:animals)    { myspeak_board("Animals", ["myspeak"]) }
  let!(:basics)     { myspeak_board("Basics", ["myspeak"]) }
  let!(:core_words) { myspeak_board("Core Words", ["myspeak", "myspeak-recommended"]) }

  it "returns the recommended Core Words board first for ?myspeak=true" do
    get "/api/public_boards", params: { myspeak: "true" }

    expect(response).to have_http_status(:ok)
    names = JSON.parse(response.body)["public_boards"].map { |b| b["name"] }

    expect(names.first).to eq("Core Words")
    expect(names).to eq(["Core Words", "Animals", "Basics"])
  end
end
