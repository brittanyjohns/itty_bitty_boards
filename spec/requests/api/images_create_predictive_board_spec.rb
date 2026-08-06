require "rails_helper"

# POST /api/images/:id/create_predictive_board is the editor's "turn this tile
# into a folder" action. When the tile lives on a Board Builder set, the page it
# creates has to JOIN that set's builder BoardGroup (issue #586) — publish,
# unpublish, delete, and the 0-slot board count all read group membership, so a
# page that never joined is reachable by tapping its tile but invisible to every
# one of those operations.
RSpec.describe "API::Images create_predictive_board", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:image) { create(:image, label: "snacks", user: user) }

  # A builder root + its BoardGroup, plus one builder_child page (the usual
  # place a user adds a new folder tile — deeper than the root).
  def build_builder_set(owner: user, published: false)
    root = create(:board, user: owner, name: "Home", published: published,
                          settings: { "builder_root" => true })
    group = BoardGroup.create!(user: owner, name: "Milo's Set", builder: true,
                               root_board_id: root.id)
    group.board_group_boards.create!(board: root)
    page = create(:board, user: owner, name: "Food", published: published,
                          settings: { "builder_child" => true })
    group.board_group_boards.create!(board: page)
    [root, group, page]
  end

  def create_folder!(parent_board, as: user)
    post "/api/images/#{image.id}/create_predictive_board",
         params: { board_id: parent_board.id, word_list: %w[chips apple], name: "Snacks" },
         headers: auth_headers(as)
  end

  it "adds the new page to the builder BoardGroup of the parent page" do
    _root, group, page = build_builder_set

    expect { create_folder!(page) }.to change { group.board_group_boards.count }.by(1)

    expect(response).to have_http_status(:ok)
    new_board = Board.find(JSON.parse(response.body)["board"]["id"])
    expect(group.boards.reload).to include(new_board)
    expect(page.board_images.find_by(image_id: image.id).predictive_board_id).to eq(new_board.id)
  end

  it "adds the new page when the tile is on the builder ROOT itself" do
    root, group, _page = build_builder_set

    create_folder!(root)

    new_board = Board.find(JSON.parse(response.body)["board"]["id"])
    expect(group.boards.reload).to include(new_board)
  end

  # countable_board_count memoizes, and `reload` does not clear the ivar — a
  # fresh User instance is the only way to observe the change.
  it "keeps the new page out of the plan's board count, like the rest of the set" do
    _root, _group, page = build_builder_set

    expect { create_folder!(page) }.not_to change { User.find(user.id).countable_board_count }
  end

  it "leaves the new page covered by the publish cascade" do
    root, _group, page = build_builder_set(published: true)

    create_folder!(page)
    new_board = Board.find(JSON.parse(response.body)["board"]["id"])
    expect(new_board.published).to be_falsey

    cascade = Boards::PublishCascade.new(root.reload)
    expect(cascade.needed?(published: true)).to be true
    cascade.apply!(published: true)
    expect(new_board.reload.published).to be true
  end

  it "is a no-op for a board that belongs to no builder set" do
    plain = create(:board, user: user, name: "Loose board")

    expect { create_folder!(plain) }.not_to change { BoardGroupBoard.count }
    expect(response).to have_http_status(:ok)
  end

  it "never inserts into another user's builder group" do
    _root, other_group, other_page = build_builder_set(owner: other_user)
    # A public image is loadable by anyone, and the parent board lookup is not
    # ownership-scoped — the group insert must be.
    image.update!(is_private: false)

    expect { create_folder!(other_page, as: user) }
      .not_to change { other_group.board_group_boards.count }
  end
end
