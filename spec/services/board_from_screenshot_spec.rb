require "rails_helper"

RSpec.describe BoardFromScreenshot, type: :service do
  let(:user) { FactoryBot.create(:user) }
  let(:import) { user.board_screenshot_imports.create!(status: "needs_review", name: "Snack Board", guessed_cols: 3) }

  def add_cell(row:, col:, label:, bg_color: "white")
    import.board_screenshot_cells.create!(row: row, col: col, label_raw: label, label_norm: label, bg_color: bg_color)
  end

  describe ".commit! board structure" do
    it "builds a static board with the import's column count and links it back" do
      add_cell(row: 0, col: 0, label: "eat")

      board = described_class.commit!(import)

      expect(board).to be_persisted
      expect(board.board_type).to eq("static")
      expect(board.large_screen_columns).to eq(3)
      expect(board.user_id).to eq(user.id)
      expect(board.board_screenshot_import_id).to eq(import.id)
      expect(import.reload.status).to eq("completed")
    end

    it "maps col -> x and row -> y in the explicit grid layout" do
      add_cell(row: 1, col: 2, label: "more")

      board = described_class.commit!(import)
      bi = board.board_images.first

      expect(bi.display_label).to eq("more")
      expect(bi.label).to eq("more")
      expect(bi.layout["lg"]).to include("x" => 2, "y" => 1, "w" => 1, "h" => 1)
      expect(bi.layout["lg"]["i"]).to eq(bi.id.to_s)
      %w[md sm xs xxs].each { |bp| expect(bi.layout[bp]).to include("x" => 2, "y" => 1) }
    end

    it "skips blank cells" do
      add_cell(row: 0, col: 0, label: "hi")
      import.board_screenshot_cells.create!(row: 0, col: 1, label_norm: "", label_raw: "", bg_color: "white")

      board = described_class.commit!(import)
      expect(board.board_images.count).to eq(1)
    end

    it "prefers a curated art-bearing image over a blank one for the label" do
      admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || FactoryBot.create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      blank = Image.create!(label: "eat", user_id: admin.id, is_private: false)
      arted = Image.create!(label: "eat", user_id: admin.id, is_private: false)
      FactoryBot.create(:doc, documentable: arted, user: admin)

      add_cell(row: 0, col: 0, label: "eat")
      board = described_class.commit!(import)

      expect(board.board_images.first.image_id).to eq(arted.id)
      expect(board.board_images.first.image_id).not_to eq(blank.id)
    end

    it "resolves a repeated label only once" do
      add_cell(row: 0, col: 0, label: "go")
      add_cell(row: 1, col: 0, label: "go")

      expect(Boards::ImageResolver).to receive(:best_arted_for).once.and_call_original
      board = described_class.commit!(import)

      images = board.board_images.map(&:image_id).uniq
      expect(images.size).to eq(1)
    end
  end

  # Categorization is deferred off the commit path (#376): newly-created tile
  # images get neutral defaults synchronously and a CategorizeImageJob finishes
  # the real categorization after commit. "apple"/"trampoline" aren't in
  # AacWordCategorizer::OVERRIDES, so without deferral each would make a
  # synchronous OpenAI call inside commit!.
  describe ".commit! deferred categorization" do
    before do
      Sidekiq::Worker.clear_all
      add_cell(row: 0, col: 0, label: "apple")
      add_cell(row: 0, col: 1, label: "trampoline")
    end

    it "does NOT categorize synchronously while committing the board" do
      expect(AacWordCategorizer).not_to receive(:categorize)

      described_class.commit!(import)
    end

    it "creates the new images with neutral defaults (POS + colors never blank)" do
      described_class.commit!(import)

      apple = Image.find_by(label: "apple", user_id: user.id)
      expect(apple).to be_present
      expect(apple.part_of_speech).to eq("default")
      expect(apple.bg_color).to eq(ColorHelper::PRESET_HEX["gray"])
      expect(apple.text_color).to be_present
    end

    it "enqueues a CategorizeImageJob for each newly created tile label" do
      expect { described_class.commit!(import) }
        .to change { CategorizeImageJob.jobs.size }.by(2)
    end

    it "reuses an existing matching image without enqueuing categorization for it" do
      existing = Image.public_img.create!(label: "apple", part_of_speech: "noun")

      expect { described_class.commit!(import) }
        .to change { CategorizeImageJob.jobs.size }.by(1) # only "trampoline"

      board_image = Image.find_by(id: existing.id).board_images.first
      expect(board_image).to be_present
      expect(existing.reload.part_of_speech).to eq("noun") # untouched
    end
  end
end
