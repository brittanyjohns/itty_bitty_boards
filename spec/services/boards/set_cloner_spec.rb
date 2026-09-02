require "rails_helper"

RSpec.describe Boards::SetCloner do
  let(:slp)          { create(:user) }
  let(:owner)        { create(:user) }
  let(:communicator) { create(:child_account, user: owner) }

  # SLP-authored set: root -> Food -> Snacks, plus a tile past the depth cap.
  let!(:source_root) { create(:board, user: slp, name: "Home") }
  let!(:source_food) { create(:board, user: slp, name: "Food") }

  def link!(from_board, to_board, label:)
    tile = create(:board_image, board: from_board, image: create(:image, label: label))
    tile.update!(predictive_board_id: to_board.id)
    tile
  end

  before do
    create(:board_image, board: source_root, image: create(:image, label: "want"))
    link!(source_root, source_food, label: "Food")
    create(:board_image, board: source_food, image: create(:image, label: "apple"))
  end

  def call!(**opts)
    described_class.new(source_root, owner: owner, communicator: communicator,
                                     voice: "echo", name: source_root.name, **opts).call
  end

  # Every clone is a REAL board now. The `template_root: true` mode that minted
  # an invisible per-communicator copy is gone along with its only caller —
  # assignment attaches a board instead of copying it.
  it "clones the root as a real, listed board and puts it on the communicator" do
    root_clone = call!
    expect(root_clone.user_id).to eq(owner.id)
    expect(root_clone.is_template).to be false
    expect(owner.boards).to include(root_clone)
    expect(communicator.child_boards.where(board_id: root_clone.id, original_board_id: source_root.id)).to exist
  end

  it "no longer accepts template_root:" do
    expect { call!(template_root: true) }.to raise_error(ArgumentError, /template_root/)
  end

  # Assigning a board is the same copy as cloning one, and it has to look like
  # the board the SLP built: a tile whose picture was authored per-tile (a
  # text-tile render, a pinned doc) keeps that picture, on the root and on the
  # sub-boards alike.
  it "keeps authored tile pictures on every board in the set" do
    source_root.board_images.find_by(label: "want")
               .update_column(:display_image_url, "https://cdn.example.com/want-text.png")
    source_food.board_images.find_by(label: "apple")
               .update_column(:display_image_url, "https://cdn.example.com/apple-text.png")

    root_clone = call!
    expect(root_clone.board_images.find_by(label: "want").display_image_url)
      .to eq("https://cdn.example.com/want-text.png")

    folder = root_clone.board_images.where.not(predictive_board_id: nil).first
    sub_clone = Board.find(folder.predictive_board_id)
    expect(sub_clone.board_images.find_by(label: "apple").display_image_url)
      .to eq("https://cdn.example.com/apple-text.png")
  end

  it "deep-clones linked sub-boards and rewires the folder tiles to the clones" do
    root_clone = call!
    folder = root_clone.board_images.where.not(predictive_board_id: nil).first
    expect(folder.predictive_board_id).not_to eq(source_food.id)

    sub_clone = Board.find(folder.predictive_board_id)
    expect(sub_clone.user_id).to eq(owner.id)
    expect(sub_clone.name).to eq("Food")
    expect(sub_clone.board_images.map(&:label)).to include("apple")
  end

  it "stamps assignment_root_id on sub-clones, and gives them NO ChildBoard rows" do
    root_clone = call!
    sub_clone = Board.find(root_clone.board_images.where.not(predictive_board_id: nil).first.predictive_board_id)

    expect(sub_clone.is_template).to be false
    expect(sub_clone.settings["assignment_root_id"]).to eq(root_clone.id)
    # `assignment_child` marked a throwaway per-communicator page. Nothing mints
    # those any more.
    expect(sub_clone.settings["assignment_child"]).to be_nil
    # Sub-boards surface through folder navigation, never as their own card.
    expect(ChildBoard.where(board_id: sub_clone.id)).not_to exist
  end

  it "keeps a pointer past the depth cap when asked to (out_of_set: :keep)" do
    snacks = create(:board, user: slp, name: "Snacks")
    deep   = create(:board, user: slp, name: "Too Deep")
    link!(source_food, snacks, label: "Snacks")
    link!(snacks, deep, label: "Deep")
    allow(described_class).to receive(:depth_cap).and_return(1)

    root_clone = call!(out_of_set: :keep)
    food_clone = Board.find(root_clone.board_images.where.not(predictive_board_id: nil).first.predictive_board_id)
    snacks_tile = food_clone.board_images.where.not(predictive_board_id: nil).first
    # Food is at the cap, so its Snacks tile keeps pointing at the SOURCE board.
    expect(snacks_tile.predictive_board_id).to eq(snacks.id)
  end

  # The MySpeak wizard's starter is the parent's OWN board, not a
  # per-communicator template — it has to show up in her board list and count
  # against her limit, because it is the board her child's public page links
  # to (#795).
  context "a copied set" do
    # ONE SLOT PER BOARD. The sub-clones used to be forced to templates
    # regardless, so a 6-board set cost exactly 1 slot and its 5 pages were
    # invisible in the owner's board list — reachable only by tapping a folder
    # tile, and impossible to find in order to edit.
    it "counts every board in the set toward the owner's board limit" do
      expect { call! }
        .to change { User.find(owner.id).countable_board_count }.by(2)
    end

    it "lists every sub-board in the owner's board list" do
      root_clone = call!
      sub_clone = Board.find(root_clone.board_images.where.not(predictive_board_id: nil).first.predictive_board_id)

      expect(owner.boards).to include(sub_clone)
    end

    it "reports how many boards it created" do
      cloner = described_class.new(source_root, owner: owner, communicator: communicator,
                                                )
      cloner.call

      expect(cloner.boards_created).to eq(2)
      expect(cloner.tiles_flattened).to eq(0)
    end
  end

  describe "max_boards: (the slot budget)" do
    it "clones only what fits and flattens the tiles whose targets were dropped" do
      cloner = described_class.new(source_root, owner: owner, communicator: communicator,
                                                max_boards: 1,
                                                out_of_set: :flatten)
      root_clone = cloner.call

      expect(cloner.boards_created).to eq(1)
      expect(cloner.tiles_flattened).to eq(1)
      expect(root_clone.board_images.where.not(predictive_board_id: nil)).to be_empty
      expect(User.find(owner.id).countable_board_count).to eq(1)
    end

    # Dropping the pointer alone leaves a muted tile with nowhere to go.
    it "leaves the dropped folder tile speaking, not silently broken" do
      link = source_root.board_images.find_by(predictive_board_id: source_food.id)
      link.update!(data: (link.data || {}).merge("mute_name" => true))

      root_clone = described_class.new(source_root, owner: owner,
                                                    max_boards: 1, out_of_set: :flatten).call
      tile = root_clone.board_images.find_by(label: link.label)

      expect(tile.door_tile?).to be(false)
      expect(tile.data["mute_name"]).to be_nil
    end

    it "prefixes sub-clone names when asked, so the new rows are distinguishable" do
      root_clone = described_class.new(source_root, owner: owner, name: "Home",
                                                    prefix_sub_names: true).call
      sub_clone = Board.find(root_clone.board_images.where.not(predictive_board_id: nil).first.predictive_board_id)

      expect(sub_clone.name).to eq("Home · Food")
    end
  end

  # A tile aiming at the board it sits on is IN the set, so it maps to the root
  # clone and keeps working. The old ownership-based flatten treated it as
  # foreign and broke it on every cross-account copy.
  it "rewires a self-link to the root clone rather than flattening it" do
    self_link = link!(source_root, source_root, label: "Home")

    root_clone = described_class.new(source_root, owner: owner,
                                                  out_of_set: :flatten).call
    tile = root_clone.board_images.find_by(label: self_link.label)

    expect(tile.predictive_board_id).to eq(root_clone.id)
  end

  # Assignment is the path that produced a communicator dashboard of boards with
  # no covers at all: clone_with_images guarded its preview enqueue on a stale
  # counter cache, so nothing here was ever rendered. The enqueue is deferred to
  # after_all_transactions_commit — which never fires under transactional
  # fixtures — so assert the synchronous marker, not the Sidekiq queue.
  it "queues a cover render for every cloned board in the set" do
    root_clone = call!
    food_clone = Board.find(root_clone.board_images.where.not(predictive_board_id: nil).first.predictive_board_id)

    expect(root_clone.reload.settings["preview_status"]).to eq("queued")
    expect(food_clone.reload.settings["preview_status"]).to eq("queued")
  end

  it "rolls back everything when a sub-board clone fails" do
    allow_any_instance_of(Board).to receive(:clone_with_images).and_wrap_original do |m, *args, **kwargs|
      m.receiver.name == "Food" ? nil : m.call(*args, **kwargs)
    end

    expect { call! }.to raise_error(described_class::CloneError)
    expect(Board.where(user_id: owner.id)).to be_empty
    expect(communicator.reload.child_boards).to be_empty
  end
end
