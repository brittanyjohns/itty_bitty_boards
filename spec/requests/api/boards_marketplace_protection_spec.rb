require "rails_helper"

# A board whose content was sold as a printable is frozen: printed sheets carry
# a QR pointing at /pb/<slug> and paper can't be re-issued. Deleting,
# unpublishing and renaming are refused outright; structural tile edits are
# refused once and then allowed with confirm_marketplace_edit=true.
#
# Everything here is 409 — a state conflict, matching the existing board_in_use
# and publish_cascade warnings. 403 stays reserved for permission/plan gates.
RSpec.describe "API::Boards marketplace protection", type: :request do
  # Admin: the boards that back a listing are the shop owner's own, and it
  # keeps the plan-limit read-only lock (403 board_locked) out of the way, so
  # every status asserted below is protection's own.
  let(:user) { create(:admin_user) }
  let(:root) { create(:board, user: user, name: "Daily Routines", published: true, slug: "daily-routines") }
  let(:page) { create(:board, user: user, name: "Snack Time", published: true, slug: "snack-time") }

  def publish_printable!(boards: [root, page])
    BoardPrintable.create!(
      board: root,
      status: "complete",
      board_ids: boards.map(&:id),
      etsy_listing_id: 1234567890,
      etsy_listing_url: "https://www.etsy.com/listing/1234567890",
    )
  end

  def body = JSON.parse(response.body)

  describe "DELETE /api/boards/:id" do
    it "refuses a protected board with 409 and the listing details" do
      publish_printable!

      delete "/api/boards/#{root.id}", headers: auth_headers(user)

      expect(response).to have_http_status(:conflict)
      expect(body["error"]).to eq("board_marketplace_protected")
      expect(body["board"]).to include("id" => root.id, "name" => "Daily Routines")
      expect(body["marketplace"]["printables"].first["etsy_listing_id"]).to eq(1234567890)
      expect(Board.exists?(root.id)).to be true
    end

    it "refuses an interior page of the printed tree" do
      publish_printable!

      delete "/api/boards/#{page.id}", headers: auth_headers(user)

      expect(response).to have_http_status(:conflict)
      expect(body["error"]).to eq("board_marketplace_protected")
      expect(body["marketplace"]["role"]).to eq("page")
    end

    # This 409 is not confirmable. board_in_use is — the client's correct
    # response there is to resend with confirm=true — so the two must not be
    # answered by the same key or the client learns to retry into a wall.
    it "is not cleared by confirm=true" do
      publish_printable!

      delete "/api/boards/#{root.id}", params: { confirm: "true" }, headers: auth_headers(user)

      expect(response).to have_http_status(:conflict)
      expect(body["error"]).to eq("board_marketplace_protected")
      expect(Board.exists?(root.id)).to be true
    end

    # Protection is checked before UsageCheck: showing the confirmable warning
    # first would teach the client to retry into the unconfirmable one.
    it "answers before board_in_use when the board is both" do
      publish_printable!
      create(:board_image, board: create(:board, user: user), predictive_board_id: root.id)

      delete "/api/boards/#{root.id}", headers: auth_headers(user)

      expect(body["error"]).to eq("board_marketplace_protected")
    end

    it "still deletes a board whose printable never reached Etsy" do
      BoardPrintable.create!(board: root, status: "complete", board_ids: [root.id])

      delete "/api/boards/#{root.id}", headers: auth_headers(user)

      expect(response.status).to be_in([200, 204])
      expect(Board.exists?(root.id)).to be false
    end

    it "deletes once protection is waived" do
      publish_printable!.waive_protection!(user: user)

      delete "/api/boards/#{page.id}", headers: auth_headers(user)

      expect(response.status).to be_in([200, 204])
      expect(Board.exists?(page.id)).to be false
    end

    describe "delete_subboards=true with a protected child" do
      # Refuse the cascade WHOLE rather than skipping the protected child:
      # skipping deletes the parent and leaves the page behind with a folder
      # tile pointing at nothing, which is the corruption this prevents.
      it "deletes nothing at all" do
        parent = create(:board, user: user, name: "Parent")
        create(:board_image, board: parent, predictive_board_id: page.id)
        publish_printable!(boards: [page])

        delete "/api/boards/#{parent.id}",
               params: { delete_subboards: "true", confirm: "true" },
               headers: auth_headers(user)

        expect(response).to have_http_status(:conflict)
        expect(body["error"]).to eq("board_marketplace_protected")
        expect(body["blocked_subboards"].map { |b| b["id"] }).to include(page.id)
        expect(Board.exists?(parent.id)).to be true
        expect(Board.exists?(page.id)).to be true
      end
    end
  end

  describe "PUT /api/boards/:id" do
    it "refuses to unpublish a protected board" do
      publish_printable!

      put "/api/boards/#{root.id}", params: { board: { published: false } }, headers: auth_headers(user)

      expect(response).to have_http_status(:conflict)
      expect(body["error"]).to eq("board_marketplace_protected")
      expect(body["blocked_action"]).to eq("unpublished")
      expect(root.reload.published).to be true
    end

    it "refuses to rename a protected board" do
      publish_printable!

      put "/api/boards/#{root.id}", params: { board: { name: "Something Else" } }, headers: auth_headers(user)

      expect(response).to have_http_status(:conflict)
      expect(body["blocked_action"]).to eq("rename")
      expect(root.reload.name).to eq("Daily Routines")
    end

    it "allows a save that re-sends the same name" do
      publish_printable!

      put "/api/boards/#{root.id}",
          params: { board: { name: "Daily Routines", description: "hello" } },
          headers: auth_headers(user)

      expect(response).to have_http_status(:success)
      expect(root.reload.description).to eq("hello")
    end

    # A favorite/tags/category save isn't structural, so it shouldn't prompt.
    it "does not prompt on a non-structural save" do
      publish_printable!

      put "/api/boards/#{root.id}", params: { board: { category: "routines" } }, headers: auth_headers(user)

      expect(response).to have_http_status(:success)
    end
  end

  describe "structural tile edits" do
    it "warns once, then goes through with confirm_marketplace_edit" do
      publish_printable!
      image = create(:image)

      put "/api/boards/#{root.id}/associate_image",
           params: { image_id: image.id },
           headers: auth_headers(user)

      expect(response).to have_http_status(:conflict)
      expect(body["error"]).to eq("board_marketplace_edit_confirmation_required")
      expect(root.reload.board_images.count).to eq(0)

      put "/api/boards/#{root.id}/associate_image",
           params: { image_id: image.id, confirm_marketplace_edit: "true" },
           headers: auth_headers(user)

      expect(response).to have_http_status(:success)
      expect(root.reload.board_images.count).to eq(1)
    end

    # Deliberately NOT `confirm`, which #update already means "yes, cascade the
    # publish" by. One click must not authorize the other thing.
    it "is not satisfied by the publish-cascade confirm param" do
      publish_printable!
      image = create(:image)

      put "/api/boards/#{root.id}/associate_image",
           params: { image_id: image.id, confirm: "true" },
           headers: auth_headers(user)

      expect(response).to have_http_status(:conflict)
      expect(body["error"]).to eq("board_marketplace_edit_confirmation_required")
    end
  end

  # SpeakAnyWay is an AAC app: reading a board, loading it and playing its audio
  # are never gated, throttled or broken. Protection is about writes only.
  describe "reads on a protected board" do
    before { publish_printable! }

    it "serves the board" do
      get "/api/boards/#{root.id}", headers: auth_headers(user)
      expect(response).to have_http_status(:success)
    end

    it "serves the PDF" do
      # Same stub as board_pdf_spec: CI has no Chrome, and what's under test
      # here is that the request isn't gated, not that Grover works.
      allow(Grover).to receive(:new).and_return(instance_double(Grover, to_pdf: "%PDF-fake"))

      get "/api/boards/#{root.id}/pdf", headers: auth_headers(user)
      expect(response.status).to be_in([200, 302])
    end
  end
end
