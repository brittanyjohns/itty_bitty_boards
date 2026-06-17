require "rails_helper"

RSpec.describe Boards::FringeTemplates do
  let(:admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  describe ".find" do
    it "returns nil for blank category" do
      expect(described_class.find(nil)).to be_nil
      expect(described_class.find("")).to be_nil
    end

    it "finds a template board by category name (case-insensitive)" do
      board = create(:board, user: admin, name: "Animals",
                     settings: { described_class::TEMPLATE_MARKER => "animals" })

      expect(described_class.find("Animals")).to eq(board)
      expect(described_class.find("animals")).to eq(board)
      expect(described_class.find("ANIMALS")).to eq(board)
    end

    it "returns nil when no template exists for the category" do
      expect(described_class.find("NonexistentCategory")).to be_nil
    end
  end

  describe ".all_templates" do
    it "returns all boards marked as fringe templates" do
      t1 = create(:board, user: admin, name: "Animals",
                  settings: { described_class::TEMPLATE_MARKER => "animals" })
      t2 = create(:board, user: admin, name: "Music",
                  settings: { described_class::TEMPLATE_MARKER => "music" })
      create(:board, user: admin, name: "Random Board") # not a template

      templates = described_class.all_templates
      expect(templates).to contain_exactly(t1, t2)
    end
  end

  describe ".seed_obf!" do
    it "creates a board from an OBF file path" do
      path = Rails.root.join("db/seeds/board_builder_sets/fringe-pages/animals.obf")
      skip "OBF seed file not present" unless File.exist?(path)

      board = described_class.seed_obf!(path)
      expect(board).to be_persisted
      expect(board.name).to eq("Animals")
      expect(board.predefined).to be(true)
      expect(board.settings[described_class::TEMPLATE_MARKER]).to eq("animals")
      expect(board.board_images.count).to be >= 6
    end
  end
end
