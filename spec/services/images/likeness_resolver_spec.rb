require "rails_helper"

RSpec.describe Images::LikenessResolver do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner) }
  let(:look) { { "skin_tone" => "brown", "gender_presentation" => "girl_woman" } }

  def communicator(user: owner, likeness: look, age_band: "4-6")
    create(:child_account, user: user, settings: { "likeness" => likeness }, details: { "age_band" => age_band })
  end

  def attach(account, to: board)
    ChildBoard.create!(child_account: account, board: to)
    to.reload
  end

  it "is nil for a board on no communicator" do
    expect(described_class.for(board: board)).to be_nil
  end

  it "uses the one communicator of the owner's the board is on, with its age band" do
    attach(communicator)

    result = described_class.for(board: board)

    expect(result.likeness.skin_tone).to eq("brown")
    expect(result.age_band).to eq("4-6")
    expect(result.prompt_clause).to include("young girl with brown skin")
  end

  # A board on two communicators could be drawn either way. Guessing puts one
  # person's look on the other's board.
  it "is nil when the board is on more than one of the owner's communicators" do
    attach(communicator)
    attach(communicator(likeness: { "skin_tone" => "light" }))

    expect(described_class.for(board: board)).to be_nil
  end

  it "ignores a communicator the board's owner does not own" do
    attach(communicator(user: create(:user)))

    expect(described_class.for(board: board)).to be_nil
  end

  it "uses a named communicator for a board that is not attached yet" do
    expect(described_class.for(board: board, communicator: communicator).likeness.skin_tone).to eq("brown")
  end

  it "refuses a named communicator the owner does not own, rather than falling back" do
    attach(communicator)

    expect(described_class.for(board: board, communicator: communicator(user: create(:user)))).to be_nil
  end

  it "is nil when the communicator has no likeness" do
    attach(communicator(likeness: {}))

    expect(described_class.for(board: board)).to be_nil
  end

  describe "the board's own override" do
    it "wins over the communicator, keeping the communicator's age band" do
      attach(communicator)
      board.update!(settings: board.settings.merge("likeness" => { "skin_tone" => "light" }))

      result = described_class.for(board: board)

      expect(result.likeness.skin_tone).to eq("light")
      expect(result.age_band).to eq("4-6")
    end

    it "applies on a board with no communicator at all" do
      board.update!(settings: board.settings.merge("likeness" => { "hair_style" => "locs" }))

      expect(described_class.for(board: board).likeness.hair_style).to eq("locs")
    end

    it "switches likeness off with mode none" do
      attach(communicator)
      board.update!(settings: board.settings.merge("likeness" => { "mode" => "none" }))

      expect(described_class.for(board: board)).to be_nil
    end
  end

  it "never applies to a menu board" do
    menu_board = create(:board, user: owner, board_type: "menu")
    menu_board.update!(settings: (menu_board.settings || {}).merge("likeness" => { "skin_tone" => "light" }))

    expect(described_class.for(board: menu_board, communicator: communicator)).to be_nil
  end
end
