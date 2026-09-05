# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "menu_boards:repack_layouts rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["menu_boards:repack_layouts"] }

  def run_task
    task.reenable
    output = StringIO.new
    original_stdout = $stdout
    $stdout = output
    task.invoke
    output.string
  ensure
    $stdout = original_stdout
  end

  around do |example|
    original = ENV.to_hash.slice("DRY_RUN", "USER_ID")
    example.run
    %w[DRY_RUN USER_ID].each { |k| ENV[k] = original[k] }
  end

  let(:user) { create(:user) }
  let!(:board) do
    create(:board, user: user, board_type: "menu", large_screen_columns: 4,
                   medium_screen_columns: 3, small_screen_columns: 2)
  end

  # The shape EnhanceImageDescriptionJob used to leave behind: the row says 4
  # columns while the tiles were packed against the controller's guessed 8.
  let!(:tiles) do
    8.times.map do |i|
      bi = create(:board_image, board: board, position: i,
                                image: create(:image, label: "item#{i}", user_id: user.id))
      bi.update_column(:layout, { "lg" => { "i" => bi.id.to_s, "x" => i, "y" => 0, "w" => 1, "h" => 1 },
                                  "md" => { "i" => bi.id.to_s, "x" => i, "y" => 0, "w" => 1, "h" => 1 },
                                  "sm" => { "i" => bi.id.to_s, "x" => i, "y" => 0, "w" => 1, "h" => 1 } })
      bi
    end
  end

  before do
    ENV.delete("DRY_RUN")
    ENV.delete("USER_ID")
  end

  it "reports the off-grid board without changing it in dry run (default)" do
    output = run_task

    expect(output).to include("would re-pack 1 menu board")
    expect(output).to include("lg 4 cols, tile reaches 8")
    expect(tiles.last.reload.layout["lg"]["x"]).to eq(7)
  end

  it "re-packs the tiles inside the board's columns when applied" do
    ENV["DRY_RUN"] = "false"
    ENV["USER_ID"] = user.id.to_s

    expect(run_task).to include("re-packed 1 menu board")

    %w[lg md sm].each do |screen|
      columns = board.reload.get_number_of_columns(screen).to_i
      extents = board.board_images.map { |bi| bi.layout[screen]["x"].to_i + bi.layout[screen]["w"].to_i }
      expect(extents.max).to be <= columns
    end
  end

  it "re-packs in menu order rather than shelf-packing the displaced tiles" do
    ENV["DRY_RUN"] = "false"
    run_task

    ordered = board.reload.board_images.order(:position).map { |bi| bi.layout["lg"] }
    expect(ordered.map { |c| [c["y"], c["x"]] }).to eq([[0, 0], [0, 1], [0, 2], [0, 3],
                                                        [1, 0], [1, 1], [1, 2], [1, 3]])
  end

  it "leaves an already-clean menu board alone" do
    board.board_images.each_with_index do |bi, i|
      bi.update_column(:layout, { "lg" => { "i" => bi.id.to_s, "x" => i % 4, "y" => i / 4, "w" => 1, "h" => 1 },
                                  "md" => { "i" => bi.id.to_s, "x" => i % 3, "y" => i / 3, "w" => 1, "h" => 1 },
                                  "sm" => { "i" => bi.id.to_s, "x" => i % 2, "y" => i / 2, "w" => 1, "h" => 1 } })
    end

    expect(run_task).to include("would re-pack 0 menu board(s); 1 already clean")
  end

  it "ignores boards outside USER_ID" do
    ENV["USER_ID"] = create(:user).id.to_s

    expect(run_task).to include("would re-pack 0 menu board(s); 0 already clean")
  end
end
