require "rails_helper"

# A board's slug is derived from its name ONCE, at creation, and then belongs to
# the URL rather than to the name. Renaming a board must not re-key `/pb/<slug>`
# — that is the link a user shares and the QR code a printable carries.
#
# Changing it is deliberate and admin-only. The published freeze (#611) is a
# separate, stricter rule that still wins on top of all of this — see
# boards_published_slug_freeze_spec.rb.
RSpec.describe "API::Boards slug on rename", type: :request do
  let(:owner) { create(:user) }
  let(:admin) { create(:admin_user) }

  def update_board(board, params, as:)
    put "/api/boards/#{board.id}", params: { board: params }, headers: auth_headers(as)
  end

  describe "an ordinary rename" do
    let(:board) { create(:board, user: owner, name: "Snack Time", slug: "snack-time", published: false) }

    it "leaves the slug untouched for the owner" do
      update_board(board, { name: "Lunch Time" }, as: owner)

      expect(response).to have_http_status(:ok)
      expect(board.reload.name).to eq("Lunch Time")
      expect(board.slug).to eq("snack-time")
    end

    it "leaves the slug untouched for an admin too" do
      update_board(board, { name: "Lunch Time" }, as: admin)

      expect(response).to have_http_status(:ok)
      expect(board.reload.name).to eq("Lunch Time")
      expect(board.slug).to eq("snack-time")
    end

    it "keeps the public URL stable so a shared link still resolves" do
      shared_url = board.public_url

      update_board(board, { name: "Lunch Time" }, as: owner)

      expect(board.reload.public_url).to eq(shared_url)
    end
  end

  describe "a non-admin trying to set the slug" do
    let(:board) { create(:board, user: owner, name: "Snack Time", slug: "snack-time", published: false) }

    it "ignores an explicit slug — the param is stripped, not rejected" do
      update_board(board, { name: "Lunch Time", slug: "lunch-time" }, as: owner)

      expect(response).to have_http_status(:ok)
      expect(board.reload.slug).to eq("snack-time")
      expect(board.name).to eq("Lunch Time")
    end

    it "ignores regenerate_slug" do
      update_board(board, { name: "Lunch Time", regenerate_slug: true }, as: owner)

      expect(response).to have_http_status(:ok)
      expect(board.reload.slug).to eq("snack-time")
    end
  end

  describe "an admin changing the slug" do
    let(:board) { create(:board, user: admin, name: "Snack Time", slug: "snack-time", published: false) }

    it "applies a hand-typed slug" do
      update_board(board, { slug: "second-snack" }, as: admin)

      expect(response).to have_http_status(:ok)
      expect(board.reload.slug).to eq("second-snack")
    end

    it "re-derives from the new name when the slug field is cleared" do
      update_board(board, { name: "Lunch Time", slug: "" }, as: admin)

      expect(response).to have_http_status(:ok)
      expect(board.reload.slug).to eq("lunch-time")
    end

    it "re-derives from the new name when regenerate_slug is set" do
      update_board(board, { name: "Lunch Time", slug: "snack-time", regenerate_slug: true }, as: admin)

      expect(response).to have_http_status(:ok)
      expect(board.reload.slug).to eq("lunch-time")
    end

    it "strips copy markers when re-deriving" do
      update_board(board, { name: "Lunch Time Copy", regenerate_slug: true }, as: admin)

      expect(board.reload.slug).to eq("lunch-time")
    end
  end

  describe "a board with no slug yet" do
    # `validates :slug, uniqueness: true` does not skip blanks and the column
    # defaults to "", so a slug-less board must be backfilled or the second one
    # fails to save.
    let(:board) { create(:board, user: owner, name: "Snack Time", slug: "", published: false) }

    it "backfills from the name on the next update, even for a non-admin" do
      update_board(board, { name: "Lunch Time" }, as: owner)

      expect(response).to have_http_status(:ok)
      expect(board.reload.slug).to eq("lunch-time")
    end
  end

  describe "the published freeze still wins" do
    let(:board) { create(:board, user: admin, name: "Snack Time", slug: "snack-time", published: true) }

    it "ignores an admin regenerate on a published board" do
      update_board(board, { name: "Lunch Time", regenerate_slug: true }, as: admin)

      expect(response).to have_http_status(:ok)
      expect(board.reload.slug).to eq("snack-time")
      expect(board.name).to eq("Lunch Time")
    end
  end
end
