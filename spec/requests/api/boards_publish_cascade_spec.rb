require "rails_helper"

# Publish cascade: publishing or unpublishing a Board Builder root cascades to
# every member board of its builder BoardGroup, behind a 409 warn+confirm that
# mirrors the board-delete flow. `published` is admin-only server-side, so the
# cascade is only ever reachable by admins.
RSpec.describe "API::Boards publish cascade", type: :request do
  let(:admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }
  let(:member_user) { create(:user) }

  def update_board(target, as:, params:)
    put "/api/boards/#{target.id}", params: params, headers: auth_headers(as)
  end

  # A builder root plus a builder BoardGroup owning two sub-boards.
  def build_builder_set(owner:, published: false, members_published: false)
    root = create(:board, user: owner, name: "Home", published: published,
                          settings: { "builder_root" => true })
    group = BoardGroup.create!(user: owner, name: "Milo's Set", builder: true,
                               root_board_id: root.id)
    group.board_group_boards.create!(board: root)
    members = ["Food", "Feelings"].map do |name|
      m = create(:board, user: owner, name: name, published: members_published,
                         settings: { "builder_child" => true })
      group.board_group_boards.create!(board: m)
      m
    end
    [root, members]
  end

  describe "unpublishing a plain board" do
    let(:board) { create(:board, user: admin, published: true) }

    it "persists published=false" do
      update_board(board, as: admin, params: { board: { published: false } })
      expect(response).to have_http_status(:ok)
      expect(board.reload.published).to be false
    end
  end

  describe "publishing a builder root with unpublished members" do
    it "returns 409 with the affected set and writes nothing" do
      root, members = build_builder_set(owner: admin)

      update_board(root, as: admin, params: { board: { published: true } })

      expect(response).to have_http_status(:conflict)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("publish_cascade_confirmation_required")
      expect(body["cascade"]["action"]).to eq("publish")
      expect(body["cascade"]["board_group"]["name"]).to eq("Milo's Set")
      expect(body["cascade"]["affected"]["count"]).to eq(2)
      expect(body["cascade"]["affected"]["names"]).to contain_exactly("Food", "Feelings")

      expect(root.reload.published).to be false
      expect(members.map { |m| m.reload.published }).to all(be false)
    end

    it "leaves other attributes in the same payload unwritten" do
      root, _members = build_builder_set(owner: admin)

      update_board(root, as: admin, params: { board: { published: true, name: "Renamed" } })

      expect(response).to have_http_status(:conflict)
      expect(root.reload.name).to eq("Home")
    end

    it "creates no images from a word_list on a declined cascade" do
      # Placement matters here in a way "nothing persisted" doesn't prove: the
      # assignment block runs find_or_create_images_from_word_list, which
      # creates Image/BoardImage rows regardless of whether @board.save ever
      # runs. A guard placed anywhere before the save (but after assignment)
      # would still leave these rows behind.
      root, _members = build_builder_set(owner: admin)

      expect {
        update_board(root, as: admin, params: { board: { published: true }, word_list: ["apple"] })
      }.not_to change { BoardImage.where(board: root).count }

      expect(response).to have_http_status(:conflict)
    end

    it "publishes the root and every member with confirm=true" do
      root, members = build_builder_set(owner: admin)

      update_board(root, as: admin, params: { board: { published: true }, confirm: "true" })

      expect(response).to have_http_status(:ok)
      expect(root.reload.published).to be true
      expect(members.map { |m| m.reload.published }).to all(be true)
    end
  end

  describe "unpublishing a published builder root" do
    it "returns 409 with the unpublish action" do
      root, _members = build_builder_set(owner: admin, published: true, members_published: true)

      update_board(root, as: admin, params: { board: { published: false } })

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["cascade"]["action"]).to eq("unpublish")
    end

    it "unpublishes the root and every member with confirm=true" do
      root, members = build_builder_set(owner: admin, published: true, members_published: true)

      update_board(root, as: admin, params: { board: { published: false }, confirm: "true" })

      expect(response).to have_http_status(:ok)
      expect(root.reload.published).to be false
      expect(members.map { |m| m.reload.published }).to all(be false)
    end
  end

  describe "when no cascade is needed" do
    it "does not prompt when members already match the target" do
      root, _members = build_builder_set(owner: admin, members_published: true)

      update_board(root, as: admin, params: { board: { published: true } })

      expect(response).to have_http_status(:ok)
      expect(root.reload.published).to be true
    end

    it "does not prompt for a board that is not a builder root" do
      plain = create(:board, user: admin, name: "Plain")
      other = create(:board, user: admin, published: false)

      update_board(plain, as: admin, params: { board: { published: true } })

      expect(response).to have_http_status(:ok)
      expect(plain.reload.published).to be true
      expect(other.reload.published).to be false
    end

    it "does not prompt when published is absent from the payload" do
      root, _members = build_builder_set(owner: admin)

      update_board(root, as: admin, params: { board: { name: "Renamed" } })

      expect(response).to have_http_status(:ok)
      expect(root.reload.name).to eq("Renamed")
    end
  end

  describe "image_ids_to_remove in the same request as a publish toggle" do
    it "removes the image without applying an unconfirmed cascade, instead of an unbreakable confirm loop" do
      # The image_ids_to_remove branch returns early and never assigns or
      # saves `published`, so a confirm=true here must not be read as "the
      # cascade applied" — the guard is skipped entirely for this request
      # shape, matching the plain image-removal behavior it always had.
      root, members = build_builder_set(owner: admin)
      image = create(:image)
      board_image = create(:board_image, board: root, image: image)

      update_board(root, as: admin,
                    params: { board: { published: true }, confirm: "true",
                              image_ids_to_remove: [image.id] })

      expect(response).to have_http_status(:ok)
      expect(root.board_images.exists?(id: board_image.id)).to be false
      expect(root.reload.published).to be false
      expect(members.map { |m| m.reload.published }).to all(be false)
    end

    it "does not raise when image_ids_to_remove is present without a board key" do
      root, _members = build_builder_set(owner: admin)
      image = create(:image)
      create(:board_image, board: root, image: image)

      update_board(root, as: admin, params: { image_ids_to_remove: [image.id] })

      expect(response).to have_http_status(:ok)
    end
  end

  describe "non-admin" do
    it "cannot trigger the cascade because published is stripped" do
      root, members = build_builder_set(owner: member_user)

      update_board(root, as: member_user, params: { board: { published: true } })

      expect(response).to have_http_status(:ok)
      expect(root.reload.published).to be false
      expect(members.map { |m| m.reload.published }).to all(be false)
    end
  end
end
