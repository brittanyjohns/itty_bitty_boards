require "rails_helper"

RSpec.describe AdminBoardBuild do
  it "defaults tags to an empty array and leaves description and audience blank" do
    build = described_class.create!(name: "Playground", columns_count: 2, tile_count: 4)

    expect(build.tags).to eq([])
    expect(build.description).to be_nil
    expect(build.audience).to be_nil
  end

  it "stores tags as an array" do
    build = described_class.create!(
      name: "Playground", columns_count: 2, tile_count: 4,
      tags: %w[playground outdoor play], description: "A board for the playground.",
      audience: "an early communicator",
    )

    expect(build.reload.tags).to eq(%w[playground outdoor play])
    expect(build.description).to eq("A board for the playground.")
    expect(build.audience).to eq("an early communicator")
  end

  # `error_message` means two different things depending on whether a set got
  # committed: on a FAILED build it's "nothing was produced", on a COMPLETE one
  # it's "the boards are fine, the tail isn't".
  describe "failure vs. warning" do
    def record(**attrs)
      described_class.create!({ name: "Playground", columns_count: 2, tile_count: 4 }.merge(attrs))
    end

    it "treats an error on a complete build as a warning with work outstanding" do
      build = record(board: FactoryBot.create(:board), status: "complete", error_message: "tempfile vanished")

      expect(build).to be_warning
      expect(build).to be_needs_finishing
    end

    it "treats a clean complete build as finished" do
      build = record(board: FactoryBot.create(:board), status: "complete")

      expect(build).not_to be_warning
      expect(build).not_to be_needs_finishing
    end

    # The historical shape: a post-commit failure that got marked "failed"
    # anyway. The set exists, so the recovery is to finish it, not rebuild it.
    it "still has work outstanding when a failed build owns a set" do
      build = record(board: FactoryBot.create(:board), status: "failed", error_message: "Errno::ENOENT")

      expect(build).to be_needs_finishing
    end

    it "has nothing to finish when a failed build produced no set" do
      expect(record(status: "failed", error_message: "boom")).not_to be_needs_finishing
    end
  end

  it "survives its board being destroyed, with board_id nullified" do
    board = FactoryBot.create(:board)
    build = described_class.create!(name: "Playground", columns_count: 2, tile_count: 4, board: board)

    expect { board.destroy! }.not_to raise_error

    expect(build.reload.board_id).to be_nil
  end
end
