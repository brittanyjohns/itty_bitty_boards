require "rails_helper"
require "rake"

RSpec.describe "board_layouts:normalize_tile_sizes" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("board_layouts:normalize_tile_sizes")
  end

  let(:task) { Rake::Task["board_layouts:normalize_tile_sizes"] }
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user, name: "At the Park", large_screen_columns: 4) }
  let(:other) { create(:board, user: user, name: "Snack Time", large_screen_columns: 4) }

  def tile(target_board, label)
    board_image = build(:board_image, board: target_board, image: create(:image, label: label, user: user))
    board_image.position = target_board.board_images.count
    board_image.skip_create_voice_audio = true
    board_image.save!
    board_image
  end

  def widen!(board_image, w: 2, h: 2)
    board_image.board.reset_layouts
    board_image.reload
    board_image.layout = board_image.layout.transform_values { |cell| cell.merge("w" => w, "h" => h) }
    board_image.skip_create_voice_audio = true
    board_image.save!
    board_image
  end

  before do
    allow(SaveAudioJob).to receive(:perform_async)
    ENV["BOARD_IDS"] = nil
    ENV["DRY_RUN"] = nil
    task.reenable
  end

  after do
    ENV.delete("BOARD_IDS")
    ENV.delete("DRY_RUN")
  end

  def run!
    task.reenable
    task.invoke
  end

  it "aborts without BOARD_IDS rather than sweeping every board" do
    expect { run! }.to raise_error(SystemExit).and output(/BOARD_IDS is required/).to_stderr
  end

  context "with a board carrying a multi-cell tile" do
    let!(:tiles) { %w[yes no stop help].map { |label| tile(board, label) } }

    before do
      allow(board).to receive(:run_generate_preview_job)
      allow(Board).to receive(:where).and_call_original
      widen!(tiles.last)
    end

    it "reports without writing on a dry run" do
      ENV["BOARD_IDS"] = board.id.to_s

      expect { run! }.to output(/\[DRY RUN\].*help 2x2/m).to_stdout
      expect(tiles.last.reload.layout["lg"]["w"]).to eq(2)
    end

    it "resets every screen to one cell when applied" do
      ENV["BOARD_IDS"] = board.id.to_s
      ENV["DRY_RUN"] = "false"

      expect { run! }.to output(/normalized 1 tile/).to_stdout

      %w[sm md lg].each do |screen|
        expect(tiles.last.reload.layout[screen].values_at("w", "h")).to eq([1, 1])
      end
    end

    it "shrinks the row count back to what the tile count needs" do
      ENV["BOARD_IDS"] = board.id.to_s
      ENV["DRY_RUN"] = "false"

      expect(Board.find(board.id).rows_for_screen_size("lg")).to eq(2)
      run!
      # A fresh instance: print_grid_layout_for_screen_size memoizes, and
      # `reload` does not clear that memo.
      expect(Board.find(board.id).rows_for_screen_size("lg")).to eq(1)
    end

    it "keeps the tile order it was given" do
      ENV["BOARD_IDS"] = board.id.to_s
      ENV["DRY_RUN"] = "false"
      run!

      expect(board.reload.board_images.order(:position).pluck(:label)).to eq(%w[yes no stop help])
    end

    it "accepts a slug" do
      ENV["BOARD_IDS"] = board.slug
      ENV["DRY_RUN"] = "false"

      expect { run! }.to output(/normalized 1 tile/).to_stdout
    end

    it "leaves a board it was not named alone" do
      other_wide = widen!(tile(other, "more"))
      ENV["BOARD_IDS"] = board.id.to_s
      ENV["DRY_RUN"] = "false"
      run!

      expect(other_wide.reload.layout["lg"]["w"]).to eq(2)
    end
  end

  it "skips a board that is already uniform" do
    tile(board, "yes")
    board.reset_layouts
    ENV["BOARD_IDS"] = board.id.to_s
    ENV["DRY_RUN"] = "false"

    expect { run! }.to output(/already uniform/).to_stdout
  end
end
