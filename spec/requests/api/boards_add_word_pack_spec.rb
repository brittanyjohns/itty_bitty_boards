require "rails_helper"

RSpec.describe "API::Boards#add_word_pack", type: :request do
  let!(:user) { create(:user) }
  let!(:board) { create(:board, user: user) }

  def json = JSON.parse(response.body)

  def add(pack_key:, words:, as: user, on: board)
    post "/api/boards/#{on.id}/add_word_pack",
         params: { pack_key: pack_key, words: words },
         headers: auth_headers(as)
  end

  before { allow(GenerateImagesJob).to receive(:perform_async) }

  it "adds a tile per requested word" do
    add(pack_key: "pronouns", words: %w[he she])

    expect(response).to have_http_status(:ok)
    expect(json["words_added"]).to eq(%w[he she])
    expect(board.reload.board_images.map(&:label)).to include("he", "she")
  end

  # The whole point of the feature. Both OpenAI calls a word add can make are
  # avoided: GenerateImagesJob (DALL-E, via max_generate: 0) and the
  # synchronous AacWordCategorizer.categorize in Image#ensure_defaults (via the
  # pack's authored part_of_speech).
  it "spends nothing: no image generation, no categorizer, no credits" do
    allow(AacWordCategorizer).to receive(:categorize).and_call_original

    expect {
      add(pack_key: "pronouns", words: %w[he she they them])
    }.not_to change(CreditTransaction, :count)

    expect(GenerateImagesJob).not_to have_received(:perform_async)
    expect(AacWordCategorizer).not_to have_received(:categorize)
    expect(response).to have_http_status(:ok)
  end

  it "colours the tiles from the pack's part of speech" do
    add(pack_key: "pronouns", words: ["he"])

    tile = board.reload.board_images.find { |bi| bi.label == "he" }
    expect(tile.part_of_speech).to eq("pronoun")
    expect(tile.bg_color).to be_present
  end

  # Classification is by communicative function: a communicator hitting "stop"
  # is protesting, so the overrides table wins over the pack's "verb".
  it "lets AacWordCategorizer::OVERRIDES win over the pack default" do
    add(pack_key: "actions", words: ["stop"])

    tile = board.reload.board_images.find { |bi| bi.label == "stop" }
    expect(tile.part_of_speech).to eq("important_function")
  end

  it "reuses existing library art instead of creating a duplicate image" do
    existing = create(:image, label: "he", user_id: User::DEFAULT_ADMIN_ID, is_private: false)

    expect { add(pack_key: "pronouns", words: ["he"]) }.not_to change(Image, :count)
    expect(board.reload.board_images.map(&:image_id)).to include(existing.id)
  end

  it "drops words the named pack doesn't carry" do
    add(pack_key: "pronouns", words: ["he", "ketchup", "DROP TABLE boards"])

    expect(json["words_added"]).to eq(["he"])
    expect(board.reload.board_images.map(&:label)).not_to include("ketchup")
  end

  it "skips words already on the board" do
    add(pack_key: "pronouns", words: ["he"])
    expect { add(pack_key: "pronouns", words: %w[he she]) }.to change { board.reload.board_images.count }.by(1)
    expect(json["words_added"]).to eq(["she"])
  end

  it "404s an unknown pack key" do
    add(pack_key: "nope", words: ["he"])

    expect(response).to have_http_status(:not_found)
    expect(json["error"]).to eq("word_pack_not_found")
  end

  it "requires authentication" do
    post "/api/boards/#{board.id}/add_word_pack", params: { pack_key: "pronouns", words: ["he"] }
    expect(response).to have_http_status(:unauthorized)
  end

  # User#board_editable? returns TRUE for a board you don't own — it measures
  # the plan lock, not permission — so ownership needs its own gate.
  it "refuses a board the caller does not own" do
    other_board = create(:board, user: create(:user))

    expect { add(pack_key: "pronouns", words: ["he"], on: other_board) }
      .not_to change { other_board.reload.board_images.count }
    expect(response).to have_http_status(:unauthorized)
  end
end
