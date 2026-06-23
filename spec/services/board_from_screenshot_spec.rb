require "rails_helper"

RSpec.describe BoardFromScreenshot, type: :service do
  let(:user) { FactoryBot.create(:user) }

  let(:import) do
    BoardScreenshotImport.create!(
      user: user,
      name: "My Screenshot Board",
      status: "needs_review",
      guessed_cols: 2,
      guessed_rows: 1,
    )
  end

  def add_cell!(row:, col:, label:)
    import.board_screenshot_cells.create!(
      row: row, col: col, label_raw: label, label_norm: label, bg_color: "white"
    )
  end

  before do
    Sidekiq::Worker.clear_all
    # "apple"/"trampoline" are not in AacWordCategorizer::OVERRIDES, so without
    # deferral each would trigger a synchronous OpenAI call inside commit!.
    add_cell!(row: 0, col: 0, label: "apple")
    add_cell!(row: 0, col: 1, label: "trampoline")
  end

  describe "#commit!" do
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

    it "builds the board with a tile per cell and marks the import completed" do
      board = described_class.commit!(import)

      expect(board.board_images.count).to eq(2)
      expect(import.reload.status).to eq("completed")
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
