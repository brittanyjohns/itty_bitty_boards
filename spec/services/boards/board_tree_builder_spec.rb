require "rails_helper"

RSpec.describe Boards::BoardTreeBuilder, type: :service do
  let(:owner) { create(:user) }
  let(:communicator) { create(:child_account, user: owner) }

  # Each tile needs a real persisted Image (board_images.image_id is NOT NULL).
  # Helper resolves a label to a freshly-created image id for this owner.
  def image_id_for(label)
    create(:image, label: label, user_id: owner.id).id
  end

  describe "#call" do
    it "builds a real 3-level linked set with correct predictive_board_id links" do
      blueprint = {
        name: "Home",
        tiles: [
          { label: "I", image_id: image_id_for("I") },
          { label: "Food", image_id: image_id_for("Food"), children: {
            name: "Food",
            tiles: [
              { label: "apple", image_id: image_id_for("apple") },
              { label: "Drinks", image_id: image_id_for("Drinks"), children: {
                name: "Drinks",
                tiles: [
                  { label: "water", image_id: image_id_for("water") },
                  { label: "juice", image_id: image_id_for("juice") },
                ],
              } },
            ],
          } },
        ],
      }

      root = described_class.new(blueprint, communicator: communicator).call

      expect(root).to be_a(Board)
      expect(root.name).to eq("Home")

      # Root's folder tile links to the Food board.
      food_tile = root.board_images.find { |bi| bi.label == "Food" }
      expect(food_tile.predictive_board_id).to be_present
      expect(food_tile.is_dynamic?).to be(true)

      food_board = Board.find(food_tile.predictive_board_id)
      expect(food_board.name).to eq("Food")

      # Food board's folder tile links to the Drinks board (level 3).
      drinks_tile = food_board.board_images.find { |bi| bi.label == "Drinks" }
      expect(drinks_tile.predictive_board_id).to be_present
      expect(drinks_tile.is_dynamic?).to be(true)

      drinks_board = Board.find(drinks_tile.predictive_board_id)
      expect(drinks_board.name).to eq("Drinks")
      expect(drinks_board.board_images.map(&:label)).to contain_exactly("water", "juice")

      # Leaf tiles never get a predictive board.
      i_tile = root.board_images.find { |bi| bi.label == "I" }
      expect(i_tile.predictive_board_id).to be_nil
    end

    it "attaches only the root to the communicator via ChildBoard" do
      blueprint = {
        name: "Home",
        tiles: [
          { label: "Food", image_id: image_id_for("Food"), children: {
            name: "Food",
            tiles: [{ label: "apple", image_id: image_id_for("apple") }],
          } },
        ],
      }

      root = nil
      expect { root = described_class.new(blueprint, communicator: communicator).call }
        .to change { communicator.child_boards.count }.by(1)

      communicator.reload
      expect(communicator.boards).to include(root)

      # Sub-boards are reachable only via predictive_board_id, not joined.
      sub_board_ids = Board.where(user_id: owner.id).where.not(id: root.id).pluck(:id)
      expect(communicator.boards.pluck(:id)).not_to include(*sub_board_ids)
      expect(communicator.child_boards.first.favorite).to be(false)
    end

    it "honors the depth cap: a folder tile at depth 2 stays a leaf" do
      blueprint = {
        name: "Level0",
        tiles: [
          { label: "A", image_id: image_id_for("A"), children: {
            name: "Level1",
            tiles: [
              { label: "B", image_id: image_id_for("B"), children: {
                name: "Level2",
                tiles: [
                  # This folder tile sits at depth 2 -> must stay a leaf.
                  { label: "C", image_id: image_id_for("C"), children: {
                    name: "Level3",
                    tiles: [{ label: "D", image_id: image_id_for("D") }],
                  } },
                ],
              } },
            ],
          } },
        ],
      }

      described_class.new(blueprint, communicator: communicator).call

      built = Board.where(user_id: owner.id)
      # Only root + level1 + level2 — Level3 is never built.
      expect(built.count).to eq(3)
      expect(built.pluck(:name)).to contain_exactly("Level0", "Level1", "Level2")

      level2 = built.find_by(name: "Level2")
      c_tile = level2.board_images.find { |bi| bi.label == "C" }
      expect(c_tile.predictive_board_id).to be_nil
    end

    it "gives every board a unique, non-blank slug" do
      blueprint = {
        name: "Home",
        tiles: [
          { label: "Food", image_id: image_id_for("Food"), children: {
            name: "Food",
            tiles: [
              { label: "Drinks", image_id: image_id_for("Drinks"), children: {
                name: "Drinks",
                tiles: [{ label: "water", image_id: image_id_for("water") }],
              } },
            ],
          } },
        ],
      }

      described_class.new(blueprint, communicator: communicator).call

      slugs = Board.where(user_id: owner.id).pluck(:slug)
      expect(slugs.size).to eq(3)
      expect(slugs).to all(be_present)
      expect(slugs.uniq.size).to eq(slugs.size)
    end

    it "rolls the whole build back when a tile fails mid-build" do
      blueprint = {
        name: "Home",
        tiles: [
          { label: "I", image_id: image_id_for("I") },
          { label: "Food", image_id: image_id_for("Food"), children: {
            name: "Food",
            tiles: [
              { label: "apple", image_id: image_id_for("apple") },
              # Bogus image_id -> add_image fails after several boards exist.
              { label: "broken", image_id: 999_999_999 },
            ],
          } },
        ],
      }

      builder = described_class.new(blueprint, communicator: communicator)

      expect { builder.call rescue nil }.not_to change { Board.where(user_id: owner.id).count }
      expect { builder.call rescue nil }.not_to change { ChildBoard.count }
      expect { builder.call }.to raise_error(StandardError)
    end

    it "raises when the communicator has no owning user" do
      ownerless = create(:child_account, user: nil)
      blueprint = { name: "Home", tiles: [] }

      expect { described_class.new(blueprint, communicator: ownerless).call }
        .to raise_error(Boards::BoardTreeBuilder::BuildError, /owning user/)
    end
  end
end
