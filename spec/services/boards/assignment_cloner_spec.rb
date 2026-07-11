require "rails_helper"

RSpec.describe Boards::AssignmentCloner do
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

  def call!
    described_class.new(source_root, owner: owner, communicator: communicator,
                                     voice: "echo", name: source_root.name).call
  end

  it "clones the root with the existing contract: is_template + ChildBoard on the communicator" do
    root_clone = call!
    expect(root_clone.user_id).to eq(owner.id)
    expect(root_clone.is_template).to be true
    expect(communicator.child_boards.where(board_id: root_clone.id, original_board_id: source_root.id)).to exist
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

  it "marks sub-clones as templates with assignment markers and NO ChildBoard rows" do
    root_clone = call!
    sub_clone = Board.find(root_clone.board_images.where.not(predictive_board_id: nil).first.predictive_board_id)

    expect(sub_clone.is_template).to be true
    expect(sub_clone.settings["assignment_child"]).to be true
    expect(sub_clone.settings["assignment_root_id"]).to eq(root_clone.id)
    expect(ChildBoard.where(board_id: sub_clone.id)).not_to exist
  end

  it "leaves a pointer past the depth cap on the source board (out_of_set: :keep)" do
    snacks = create(:board, user: slp, name: "Snacks")
    deep   = create(:board, user: slp, name: "Too Deep")
    link!(source_food, snacks, label: "Snacks")
    link!(snacks, deep, label: "Deep")
    allow(described_class).to receive(:depth_cap).and_return(1)

    root_clone = call!
    food_clone = Board.find(root_clone.board_images.where.not(predictive_board_id: nil).first.predictive_board_id)
    snacks_tile = food_clone.board_images.where.not(predictive_board_id: nil).first
    # Food is at the cap, so its Snacks tile keeps pointing at the SOURCE board.
    expect(snacks_tile.predictive_board_id).to eq(snacks.id)
  end

  it "does not change the owner's countable board count (clones are templates)" do
    expect { call! }.not_to change { owner.reload.countable_board_count }
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
