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

  # A Core 60 page is 10 columns and a Core 84 page is 12. Boards::NavRowSync
  # widens a clone's lg count and moves no tile, so cloning the wrong variant
  # leaves content stopping short of the grid it was dropped into.
  describe ".find with a core_template" do
    def template(category, variant, name: category.titleize)
      settings = { described_class::TEMPLATE_MARKER => category }
      settings[described_class::VARIANT_MARKER] = variant if variant
      create(:board, user: admin, name: name, settings: settings)
    end

    it "prefers the template authored for that core set" do
      sixty = template("animals", "core-60", name: "Animals 60")
      eighty = template("animals", "core-84", name: "Animals 84")

      expect(described_class.find("Animals", core_template: "core-60")).to eq(sixty)
      expect(described_class.find("Animals", core_template: "core-84")).to eq(eighty)
    end

    # Hand-registered, or seeded before variants existed. It is the best guess
    # available and beats charging the user AI credits for a page we have.
    it "falls back to a template carrying no core set" do
      legacy = template("animals", nil)

      expect(described_class.find("Animals", core_template: "core-84")).to eq(legacy)
    end

    it "prefers an exact variant over a variant-less row" do
      template("animals", nil, name: "Animals legacy")
      exact = template("animals", "core-84", name: "Animals 84")

      expect(described_class.find("Animals", core_template: "core-84")).to eq(exact)
    end

    # Last resort: a page needing a repack still beats :ai_generated.
    # Boards::TemplateHealth names the missing variant so the gap is visible.
    it "falls back to the other core set rather than nothing" do
      sixty = template("animals", "core-60")

      expect(described_class.find("Animals", core_template: "core-84")).to eq(sixty)
    end

    it "still lets the oldest row win among rows sharing a variant" do
      first = template("animals", "core-84", name: "Animals A")
      template("animals", "core-84", name: "Animals B")

      expect(described_class.find("Animals", core_template: "core-84")).to eq(first)
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

  describe ".seed_data!" do
    before { admin } # seed_data! raises without the DEFAULT_ADMIN_ID row

    it "stamps the core set the .obf declares" do
      board = described_class.seed_data!(
        "format" => "open-board-0.1", "id" => "fringe:core-84:spec", "locale" => "en",
        "name" => "Animals", described_class::VARIANT_KEY => "core-84",
        "grid" => { "rows" => 1, "columns" => 2, "order" => [[1, 2]] },
        "buttons" => [{ "id" => 1, "label" => "dog", "part_of_speech" => "noun" },
                      { "id" => 2, "label" => "cat", "part_of_speech" => "noun" }],
        "images" => [], "sounds" => [],
      )

      expect(board.settings[described_class::VARIANT_MARKER]).to eq("core-84")
      expect(described_class.core_template_for(board)).to eq("core-84")
    end

    # An unrecognized value must not be stored: every reader treats the marker
    # as one of VARIANTS, and a stray string is a variant nothing can select.
    it "drops a core set it does not recognize" do
      board = described_class.seed_data!(
        "format" => "open-board-0.1", "id" => "fringe:spec-bogus", "locale" => "en",
        "name" => "Animals", described_class::VARIANT_KEY => "core-99",
        "grid" => { "rows" => 1, "columns" => 1, "order" => [[1]] },
        "buttons" => [{ "id" => 1, "label" => "dog", "part_of_speech" => "noun" }],
        "images" => [], "sounds" => [],
      )

      expect(board.settings).not_to have_key(described_class::VARIANT_MARKER)
      expect(described_class.core_template_for(board)).to be_nil
    end
  end

  # The two variants of one category seed as the SAME admin, so a shared obf_id
  # would make one overwrite the other — the #278 collision, one directory over.
  # This is also the pass that heals a stale row: the eleven templates were
  # re-authored and production was never re-seeded, so the rows kept a grid
  # three quarters smaller than their source.
  describe "seeding both variants of one category" do
    before { admin }

    it "produces two distinct boards at the authored widths" do
      sixty = described_class.seed_obf!(described_class::SEED_DIR.join("core-60", "animals.obf"))
      eighty = described_class.seed_obf!(described_class::SEED_DIR.join("core-84", "animals.obf"))

      expect(sixty.id).not_to eq(eighty.id)
      expect(sixty.large_screen_columns).to eq(described_class::EXPECTED_COLUMNS["core-60"])
      expect(eighty.large_screen_columns).to eq(described_class::EXPECTED_COLUMNS["core-84"])
      expect(sixty.board_images.count).to eq(40)
      expect(eighty.board_images.count).to eq(60)

      expect(described_class.find("Animals", core_template: "core-60")).to eq(sixty)
      expect(described_class.find("Animals", core_template: "core-84")).to eq(eighty)
    end

    it "heals a row seeded from an older, smaller source" do
      board = described_class.seed_obf!(described_class::SEED_DIR.join("core-60", "animals.obf"))

      # Roll it back to the pre-#747 shape: 3 rows x 4 columns, 12 words.
      board.board_images.order(:position).offset(12).destroy_all
      board.update!(number_of_columns: 4, large_screen_columns: 4)

      reseeded = described_class.seed_obf!(described_class::SEED_DIR.join("core-60", "animals.obf"))

      expect(reseeded.id).to eq(board.id)
      expect(reseeded.large_screen_columns).to eq(10)
      expect(reseeded.board_images.count).to eq(40)
    end
  end

  describe ".seed_files" do
    it "reaches sources nested one directory per core set" do
      relative = described_class.seed_files.map do |path|
        Pathname.new(path).relative_path_from(described_class::SEED_DIR).to_s
      end

      expect(relative).to all(match(%r{\A(core-60|core-84)/.+\.obf\z}))
      expect(relative).to include("core-60/animals.obf", "core-84/animals.obf")
    end
  end

  describe ".seed_obf!" do
    it "creates a board from an OBF file path" do
      path = Rails.root.join("db/seeds/board_builder_sets/fringe-pages/core-60/animals.obf")
      skip "OBF seed file not present" unless File.exist?(path)
      admin # force-create the DEFAULT_ADMIN_ID user

      board = described_class.seed_obf!(path)
      expect(board).to be_persisted
      expect(board.name).to eq("Animals")
      expect(board.predefined).to be(true)
      expect(board.settings[described_class::TEMPLATE_MARKER]).to eq("animals")
      expect(board.board_images.count).to be >= 6
    end
  end
end
