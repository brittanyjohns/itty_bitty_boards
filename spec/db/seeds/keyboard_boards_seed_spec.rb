require "rails_helper"

RSpec.describe "db/seeds/keyboard_boards.rb", type: :model do
  let(:seed_path) { Rails.root.join("db/seeds/keyboard_boards.rb") }

  def run_seed
    load seed_path.to_s
  end

  before do
    FactoryBot.create(:user, id: User::DEFAULT_ADMIN_ID)
    allow(SaveAudioJob).to receive(:perform_async)
    allow(CategorizeImageJob).to receive(:perform_async)
  end

  it "creates both keyboard boards, unpublished, with 28 tiles each" do
    run_seed

    boards = Board.keyboards
    expect(boards.pluck(:slug)).to match_array(%w[keyboard-abc keyboard-qwerty])

    boards.each do |b|
      expect(b.keyboard?).to be(true)
      expect(b.predefined).to be(true)
      expect(b.published).to be(false)
      expect(b.is_template).to be(false)
      expect(b.category).to eq("letters")
      expect(b.tags).to include("keyboard")
      expect(b.user_id).to eq(User::DEFAULT_ADMIN_ID)
      expect(b.board_images.count).to eq(28)
      expect(b.settings["custom_screen_layouts"]).to match_array(%w[md sm])
    end
  end

  it "flags letter tiles and action tiles via the data contract" do
    run_seed
    board = Board.find_by!(slug: "keyboard-abc")

    letter = board.board_images.find_by!(label: "A")
    expect(letter.data).to include("tile_type" => "letter")

    space = board.board_images.find_by!(label: "Space")
    expect(space.data).to include("tile_type" => "action", "tile_action" => "space")

    delete = board.board_images.find_by!(label: "Delete")
    expect(delete.data).to include("tile_type" => "action", "tile_action" => "backspace")
  end

  it "authors keyboard-shaped layouts for every screen size" do
    run_seed

    abc_space = Board.find_by!(slug: "keyboard-abc").board_images.find_by!(label: "Space")
    qwerty = Board.find_by!(slug: "keyboard-qwerty")
    qwerty_space = qwerty.board_images.find_by!(label: "Space")
    qwerty_delete = qwerty.board_images.find_by!(label: "Delete")
    qwerty_a = qwerty.board_images.find_by!(label: "A")

    %w[lg md sm xs xxs].each do |screen|
      expect(abc_space.layout[screen]).to include("w" => 2, "y" => 4)
      expect(qwerty_space.layout[screen]).to include("w" => 6, "y" => 3)
      expect(qwerty_delete.layout[screen]).to include("w" => 3, "y" => 2)
      # QWERTY stagger: A starts the second row, not the first
      expect(qwerty_a.layout[screen]).to include("x" => 0, "y" => 1)
    end

    expect(qwerty.large_screen_columns).to eq(10)
    expect(qwerty.small_screen_columns).to eq(10)
  end

  it "colors vowels, consonants, and action tiles distinctly" do
    run_seed
    board = Board.find_by!(slug: "keyboard-abc")

    expect(board.board_images.find_by!(label: "A").bg_color).to eq("#FDE68A")
    expect(board.board_images.find_by!(label: "B").bg_color).to eq("#DBEAFE")
    expect(board.board_images.find_by!(label: "Space").bg_color).to eq("#E5E7EB")
  end

  it "is idempotent — re-running does not duplicate boards or tiles" do
    run_seed
    counts_before = Board.keyboards.map { |b| [b.slug, b.board_images.count] }.to_h

    run_seed
    counts_after = Board.keyboards.map { |b| [b.slug, b.board_images.count] }.to_h

    expect(Board.keyboards.count).to eq(2)
    expect(counts_after).to eq(counts_before)
  end

  it "never unpublishes an already-published keyboard on re-run" do
    run_seed
    Board.find_by!(slug: "keyboard-abc").update!(published: true)

    run_seed
    expect(Board.find_by!(slug: "keyboard-abc").published).to be(true)
  end

  it "stays out of public_boards until published, then appears" do
    run_seed
    expect(Board.public_boards.pluck(:slug)).not_to include("keyboard-abc", "keyboard-qwerty")

    Board.keyboards.update_all(published: true)
    expect(Board.public_boards.pluck(:slug)).to include("keyboard-abc", "keyboard-qwerty")
  end

  it "serializes the tile data contract in the native grid payload" do
    run_seed
    payload = Board.find_by!(slug: "keyboard-abc").api_view_for_native_grid(nil)

    expect(payload[:board_type]).to eq("keyboard")

    space = payload[:images].find { |img| img[:label] == "Space" }
    expect(space[:data]).to include("tile_type" => "action", "tile_action" => "space")

    letter = payload[:images].find { |img| img[:label] == "Q" }
    expect(letter[:data]).to include("tile_type" => "letter")
  end

  it "preserves tile data flags when a user clones a keyboard board" do
    run_seed
    user = FactoryBot.create(:user)
    source = Board.find_by!(slug: "keyboard-abc")

    clone = source.clone_with_images(user.id, "My Keyboard")

    expect(clone).to be_persisted
    expect(clone.board_type).to eq("keyboard")
    expect(clone.keyboard?).to be(true)
    expect(clone.predefined).to be(false)
    expect(clone.board_images.count).to eq(28)

    cloned_space = clone.board_images.find_by!(label: "Space")
    expect(cloned_space.data).to include("tile_type" => "action", "tile_action" => "space")
    expect(clone.board_images.find_by!(label: "A").data).to include("tile_type" => "letter")
  end
end
