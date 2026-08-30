# frozen_string_literal: true

require "rails_helper"

# The bound the board-limit gate reserves before a Board Builder run. Every
# number here is derived from a constant rather than written down, so adding a
# seed page or a GLP function board moves the bound instead of silently breaking
# it — the "matches a real build" example below is what actually enforces that.
RSpec.describe Boards::BuilderSetSize do
  describe ".worst_case" do
    it "counts root + the whole authored seed set + max fringe + phrases + favorites" do
      expected = {
        "starter" => 1 + 8 + 6 + (1 + Boards::GlpTemplates::TEMPLATES.size) + 1,
        "standard" => 1 + 8 + 10 + (1 + Boards::GlpTemplates::TEMPLATES.size) + 1,
        "extended" => 1 + 11 + 15 + (1 + Boards::GlpTemplates::TEMPLATES.size) + 1,
      }

      expected.each do |level, size|
        expect(described_class.worst_case(level)).to eq(size), "#{level} expected #{size}"
      end
    end

    it "grows with the level" do
      sizes = Boards::StructurePlanner::LEVEL_KEYS.map { |k| described_class.worst_case(k) }
      expect(sizes).to eq(sizes.sort)
    end

    it "is case- and symbol-insensitive" do
      expect(described_class.worst_case(:Extended)).to eq(described_class.worst_case("extended"))
    end

    # A legacy `template:` build (a robust-set slug or a StarterBlueprints key)
    # never reaches StructurePlanner, so there is no level to size it by.
    it "falls back to the roomiest level for a legacy template key" do
      expect(described_class.worst_case("home")).to eq(described_class.legacy_worst_case)
      expect(described_class.worst_case("core-60")).to eq(described_class.legacy_worst_case)
      expect(described_class.worst_case(nil)).to eq(described_class.legacy_worst_case)
    end

    it "legacy_worst_case is the max over the shipped levels" do
      expect(described_class.legacy_worst_case).to eq(
        Boards::StructurePlanner::LEVEL_KEYS.map { |k| described_class.worst_case(k) }.max,
      )
    end
  end

  # The load-bearing one: if a real build ever persists more boards than the
  # gate reserved, a user can overrun their cap. This is what catches a new seed
  # page or GLP board that the arithmetic above didn't hear about.
  describe "against a real build", type: :request do
    let(:user) { create(:user, settings: { "board_limit" => 500 }) }
    let(:communicator) { create(:child_account, user: user) }
    let(:headers) { auth_headers(user).merge("Content-Type" => "application/json") }

    before { allow_any_instance_of(Grover).to receive(:to_png).and_return(ChunkyPNG::Image.new(1, 1).to_blob) }

    # A stand-in for `bin/rails vocab_sets:seed`: an admin-owned Core 84 root
    # with every authored fringe page, so SeededSetCloner actually clones a set
    # and the bound is measured against real work rather than a bare root.
    # RobustSets.all_roots is scoped to the seeder (DEFAULT_ADMIN_ID +
    # predefined), so the fixture has to be owned that way.
    def seed_core_84!
      admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      root = create(:board, user: admin, name: "Core 84", predefined: true, published: true)

      Boards::StructurePlanner::SEED_SET_PAGES.fetch("core-84").each do |page_name|
        page = create(:board, user: admin, name: page_name, predefined: true, published: true)
        create(:board_image, board: page, label: page_name.downcase,
                             image: create(:image, label: page_name.downcase, user_id: admin.id))
        tile = create(:board_image, board: root, label: page_name, display_label: page_name,
                                    image: create(:image, label: page_name, user_id: admin.id))
        tile.update!(predictive_board_id: page.id)
      end

      Boards::RobustSets.mark_root!(root, "core-84")
      root
    end

    it "bounds what an extended build actually persists" do
      seed_core_84!

      post "/api/v1/board_builder",
           params: { communicator_id: communicator.id, level: "extended",
                     interests: ["dinosaurs", "pizza"] }.to_json,
           headers: headers
      expect(response).to have_http_status(:created)
      BuildBoardSetJob.drain

      fresh = User.find(user.id)
      expect(fresh.countable_board_count).to be > 1
      expect(fresh.countable_board_count).to be <= described_class.worst_case("extended")
    end
  end
end
