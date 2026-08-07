require "rails_helper"

# A published board's slug is permanent: `/pb/<slug>` is what the QR codes on
# printed board printables encode, and printed paper can't be re-issued (#611).
# The change is IGNORED rather than rejected — the frontend re-derives the slug
# from the name on every rename, so a 422 would break ordinary board renaming.
RSpec.describe "API::Boards published slug freeze", type: :request do
  let(:user) { create(:user) }

  def update_board(board, params)
    put "/api/boards/#{board.id}", params: params, headers: auth_headers(user)
  end

  context "when the board is published" do
    let(:board) { create(:board, user: user, name: "Snack Time", published: false) }

    # Slug first, publish second — the real order.
    before do
      board.generate_unique_slug
      board.save!
      board.update!(published: true)
    end

    it "keeps the old slug and still applies the rest of the update" do
      original_slug = board.slug
      expect(original_slug).to be_present

      update_board(board, board: { name: "Lunch Time", slug: "lunch-time" })

      expect(response).to have_http_status(:ok)
      expect(board.reload.slug).to eq(original_slug)
      expect(board.name).to eq("Lunch Time")
    end

    it "leaves the already-printed /pb/<slug> URL resolving to the board" do
      printed_slug = board.slug

      update_board(board, board: { name: "Lunch Time", slug: "lunch-time" })

      get "/api/boards/#{printed_slug}"
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["id"]).to eq(board.id)
    end

    it "keeps public_url stable across the rename" do
      printed_url = board.public_url

      update_board(board, board: { name: "Lunch Time", slug: "lunch-time" })

      expect(board.reload.public_url).to eq(printed_url)
    end
  end

  context "when the board is not published" do
    let(:board) { create(:board, user: user, name: "Draft Board", published: false) }

    before { board.generate_unique_slug && board.save! }

    it "still renames the slug — nothing shareable has been handed out" do
      update_board(board, board: { name: "Second Draft", slug: "second-draft" })

      expect(response).to have_http_status(:ok)
      expect(board.reload.slug).to eq("second-draft")
    end
  end
end
