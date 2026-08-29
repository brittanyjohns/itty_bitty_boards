require "rails_helper"

RSpec.describe Boards::SeedSourceExporter do
  let(:admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }
  let(:source_path) { Rails.root.join("db/seeds/board_builder_sets/fringe-pages/animals.obf") }

  describe "#call" do
    it "emits the authored shape, not the app's export shape" do
      board = create(:board, user: admin, name: "Animals", obf_id: "fringe:animals",
                     number_of_columns: 2, large_screen_columns: 2)
      image = create(:image, label: "dog")
      tile = create(:board_image, board: board, image: image, label: "dog", position: 0,
                    part_of_speech: "noun")
      tile.update_columns(layout: { "lg" => { "x" => 0, "y" => 0, "w" => 1, "h" => 1 } },
                          data: { "obf_button_id" => "7" })

      doc = described_class.new(board.reload).call

      expect(doc["format"]).to eq("open-board-0.1")
      # Namespaced, because Board.from_obf upserts on (user_id, obf_id) and both
      # sets seed as the same admin.
      expect(doc["id"]).to eq("fringe:animals")
      expect(doc["images"]).to eq([])
      expect(doc["sounds"]).to eq([])
      expect(doc["buttons"].first).to include("id" => 7, "label" => "dog", "part_of_speech" => "noun")
      expect(doc["grid"]["order"].flatten).to include(7)
    end

    it "hands an authored id to a tile added in the board editor" do
      board = create(:board, user: admin, name: "Animals", obf_id: "fringe:animals",
                     number_of_columns: 2, large_screen_columns: 2)
      stamped = create(:board_image, board: board, image: create(:image, label: "dog"), label: "dog", position: 0)
      stamped.update_columns(data: { "obf_button_id" => "1" })
      create(:board_image, board: board, image: create(:image, label: "cat"), label: "cat", position: 1)

      ids = described_class.new(board.reload).call["buttons"].map { |b| b["id"] }

      expect(ids).to contain_exactly(1, 2)
    end
  end

  describe "#filename" do
    it "names the file after the un-namespaced id" do
      board = create(:board, user: admin, name: "Animals", obf_id: "fringe:animals")
      expect(described_class.new(board).filename).to eq("animals.obf")
    end
  end

  # The point of the export: what comes out can be committed back over the seed
  # file and re-seeded. If a round trip changed the board, the export is a lie.
  describe "round trip through the seeder" do
    it "re-seeds to the same board" do
      skip "OBF seed file not present" unless File.exist?(source_path)
      admin

      seeded = Boards::FringeTemplates.seed_obf!(source_path)
      before = seeded.board_images.order(:position).map { |bi| [bi.label, bi.part_of_speech] }

      exported = described_class.new(seeded.reload).call
      reseeded = Boards::FringeTemplates.seed_data!(exported)

      expect(reseeded.id).to eq(seeded.id)
      expect(reseeded.board_images.order(:position).map { |bi| [bi.label, bi.part_of_speech] }).to eq(before)

      # And the exported document is the authored one: same id, same grid, same
      # buttons — so it can be committed over the seed file.
      source = JSON.parse(File.read(source_path))
      expect(exported["id"]).to eq(source["id"])
      expect(exported["grid"]["columns"]).to eq(source["grid"]["columns"])
      expect(exported["grid"]["rows"]).to eq(source["grid"]["rows"])
      expect(exported["buttons"].map { |b| b["label"] }.sort)
        .to eq(source["buttons"].map { |b| b["label"] }.sort)
      expect(exported["grid"]["order"]).to eq(source["grid"]["order"])
    end
  end
end
