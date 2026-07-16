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

    it "marks the root builder_root and sub-boards builder_child (issue #269 / #270)" do
      blueprint = {
        name: "Home",
        tiles: [
          { label: "I", image_id: image_id_for("I") },
          { label: "Food", image_id: image_id_for("Food"), children: {
            name: "Food",
            tiles: [{ label: "apple", image_id: image_id_for("apple") }],
          } },
        ],
      }

      root = described_class.new(blueprint, communicator: communicator).call

      # Root is the re-run detector marker, and stays countable (not builder_child).
      expect(root.settings["builder_root"]).to be(true)
      expect(root.settings["builder_child"]).to be_falsey

      food_tile = root.board_images.find { |bi| bi.label == "Food" }
      sub_board = Board.find(food_tile.predictive_board_id)
      expect(sub_board.settings["builder_child"]).to be(true)
      expect(sub_board.settings["builder_root"]).to be_falsey
    end

    it "raises when the communicator has no owning user" do
      ownerless = create(:child_account, user: nil)
      blueprint = { name: "Home", tiles: [] }

      expect { described_class.new(blueprint, communicator: ownerless).call }
        .to raise_error(Boards::BoardTreeBuilder::BuildError, /owning user/)
    end

    context "with an adopted root (async path via BuildBoardSetJob)" do
      # Mirrors the controller's in-request root creation.
      def precreated_root
        root = Board.new(name: "Home", user: owner)
        root.board_type = "dynamic"
        root.assign_parent
        root.generate_unique_slug
        root.settings = (root.settings || {}).merge("builder_root" => true)
        root.status = "building_board"
        root.save!
        communicator.child_boards.create!(board: root, created_by_id: owner.id).update!(favorite: true)
        root
      end

      let(:blueprint) do
        {
          name: "Home",
          tiles: [
            { label: "I", image_id: image_id_for("I") },
            { label: "Food", image_id: image_id_for("Food"), children: {
              name: "Food",
              tiles: [{ label: "apple", image_id: image_id_for("apple") }],
            } },
          ],
        }
      end

      it "builds the tree into the adopted root instead of creating a new one" do
        root = precreated_root

        returned = nil
        expect {
          returned = described_class.new(blueprint, communicator: communicator, root: root).call
        }.to change { Board.where(user_id: owner.id).count }.by(1) # only the Food sub-board

        expect(returned.id).to eq(root.id)
        expect(root.reload.board_images.map(&:label)).to contain_exactly("I", "Food")
        food_tile = root.board_images.find { |bi| bi.label == "Food" }
        expect(Board.find(food_tile.predictive_board_id).settings["builder_child"]).to be(true)
      end

      it "preserves the adopted root's identity (name, slug, status) and does not re-attach" do
        root = precreated_root
        original_slug = root.slug

        expect {
          described_class.new(blueprint, communicator: communicator, root: root).call
        }.not_to change { communicator.child_boards.count }

        root.reload
        expect(root.name).to eq("Home")
        expect(root.slug).to eq(original_slug)
        # Status is the JOB's to flip; the builder must not touch it.
        expect(root.status).to eq("building_board")
        expect(communicator.child_boards.where(board_id: root.id).count).to eq(1)
      end

      it "rolls back children/tiles on failure but leaves the adopted root" do
        root = precreated_root
        bad = blueprint.deep_dup
        bad[:tiles] << { label: "broken", image_id: 999_999_999 }

        expect {
          described_class.new(bad, communicator: communicator, root: root).call
        }.to raise_error(StandardError)

        expect(root.reload).to be_persisted
        expect(root.board_images.count).to eq(0)
        expect(Board.where(user_id: owner.id).where.not(id: root.id).count).to eq(0)
      end
    end

    # A set built for a user with no communicator — assignable to one later.
    context "without a communicator" do
      let(:blueprint) do
        { name: "Home",
          tiles: [
            { label: "I", image_id: image_id_for("I") },
            { label: "Food", image_id: image_id_for("Food"), children: {
              name: "Food", tiles: [{ label: "apple", image_id: image_id_for("apple") }],
            } },
          ] }
      end

      it "builds the tree for the owner and creates no ChildBoard" do
        root = nil
        expect {
          root = described_class.new(blueprint, owner: owner, favorite_root: true).call
        }.not_to change { ChildBoard.count }

        expect(root.user_id).to eq(owner.id)
        expect(root.settings["builder_root"]).to be(true)

        food_tile = root.board_images.find { |bi| bi.label == "Food" }
        food_board = Board.find(food_tile.predictive_board_id)
        expect(food_board.board_images.map(&:label)).to eq(["apple"])
        expect(food_board.settings["builder_child"]).to be(true)
      end

      it "falls back to the owner's voice" do
        owner.update!(settings: { "voice" => { "name" => "openai:nova" } })

        root = described_class.new(blueprint, owner: owner).call

        expect(root.voice).to eq("openai:nova")
      end

      it "raises without an owner or a communicator to derive one from" do
        expect {
          described_class.new(blueprint).call
        }.to raise_error(described_class::BuildError, /no owning user/)
      end
    end
  end
end
