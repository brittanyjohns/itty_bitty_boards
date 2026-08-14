require "rails_helper"

RSpec.describe Boards::AdminBuilder::ExistingBoards do
  let!(:admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  # Slugs are unique and several examples deliberately create same-named
  # boards, so each one gets its own suffixed slug the way Build does.
  def admin_board(name:, columns: 6, **overrides)
    board = Board.new({
      name: name, user: admin, parent: admin, published: true, board_type: "static",
      large_screen_columns: columns, number_of_columns: columns,
    }.merge(overrides))
    board.generate_unique_slug
    board.save!
    board
  end

  describe ".matching" do
    it "finds a published admin board by name, case-insensitively" do
      board = admin_board(name: "Feelings")

      expect(described_class.matching(["feelings"]).keys).to eq(["feelings"])
      expect(described_class.matching(["FEELINGS"])["feelings"].map(&:id)).to eq([board.id])
    end

    it "reports the grid and tile count the picker shows" do
      board = admin_board(name: "Feelings", columns: 4)
      2.times { |i| board.add_image(Image.create!(label: "w#{i}", user_id: admin.id).id) }

      match = described_class.matching(["Feelings"])["feelings"].first

      expect(match.columns).to eq(4)
      expect(match.tile_count).to eq(2)
      expect(match.summary).to include("4 cols", "2 tiles")
    end

    it "puts a board on the same grid first" do
      other = admin_board(name: "Feelings", columns: 8)
      same = admin_board(name: "Feelings", columns: 6)

      ranked = described_class.matching(["Feelings"], columns: 6)["feelings"].map(&:id)

      expect(ranked).to eq([same.id, other.id])
    end

    it "is empty when nothing matches, and costs no query with no names" do
      admin_board(name: "Feelings")

      expect(described_class.matching(["Nowhere"])).to eq({})
      expect(described_class.matching([])).to eq({})
      expect(described_class.matching([nil, "  "])).to eq({})
    end

    it "caps the options offered per page" do
      (described_class::MAX_MATCHES + 2).times { admin_board(name: "Feelings") }

      expect(described_class.matching(["Feelings"])["feelings"].size).to eq(described_class::MAX_MATCHES)
    end
  end

  describe "what may be linked" do
    it "excludes an unpublished board and one owned by someone else" do
      admin_board(name: "Feelings", published: false)
      admin_board(name: "Feelings", user: create(:user))

      expect(described_class.matching(["Feelings"])).to eq({})
    end

    # BoardImage#door_tile? reads a tile pointing at a predictive board as a
    # dynamic WORD tile, so linking one would build a door that isn't a door.
    it "excludes a predictive board" do
      admin_board(name: "Feelings", board_type: "predictive")

      expect(described_class.matching(["Feelings"])).to eq({})
    end

    it "excludes a menu board" do
      admin_board(name: "Feelings", board_type: "menu")

      expect(described_class.matching(["Feelings"])).to eq({})
    end

    # Board.public_boards keys on `predefined`, which admin Board Builder boards
    # deliberately are not — using that scope here would hide exactly the boards
    # this page produces.
    it "includes a builder board, which is published but not predefined" do
      board = admin_board(name: "Feelings", predefined: false,
                          settings: { "admin_builder" => true })

      expect(described_class.matching(["Feelings"])["feelings"].map(&:id)).to eq([board.id])
    end
  end

  describe ".find" do
    it "returns a linkable board and nothing else" do
      board = admin_board(name: "Feelings")
      unpublished = admin_board(name: "Hidden", published: false)

      expect(described_class.find(board.id)).to eq(board)
      expect(described_class.find(board.id.to_s)).to eq(board)
      expect(described_class.find(unpublished.id)).to be_nil
      expect(described_class.find(nil)).to be_nil
      expect(described_class.find("")).to be_nil
    end
  end
end
