# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "board_layouts:reflow_sm_md rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["board_layouts:reflow_sm_md"] }

  def run_task
    task.reenable
    task.invoke
  end

  around do |example|
    original = ENV.to_hash.slice("DRY_RUN", "USER_ID", "KEEP_COLUMNS")
    example.run
    %w[DRY_RUN USER_ID KEEP_COLUMNS].each { |k| ENV[k] = original[k] }
  end

  let(:user) { create(:user) }
  let!(:board) { create(:board, user: user) }

  before do
    # Wide lg, stale non-proportional md/sm columns + tiles authored only on lg.
    board.update_columns(large_screen_columns: 12, medium_screen_columns: 6, small_screen_columns: 4)
    6.times do |i|
      bi = create(:board_image, board: board, position: i,
                                image: create(:image, label: "w#{i}", user_id: user.id))
      bi.update_column(:layout, { "lg" => { "i" => bi.id.to_s, "x" => i, "y" => 0, "w" => 1, "h" => 1 } })
    end
  end

  it "previews without changing columns or layouts in dry-run (default)" do
    ENV.delete("DRY_RUN")
    ENV.delete("USER_ID")
    expect { run_task }.to output(/DRY RUN/).to_stdout
    board.reload
    expect(board.medium_screen_columns).to eq(6) # unchanged
    expect(board.board_images.first.reload.layout["sm"]).to be_nil
  end

  it "recomputes proportional columns and reflows md/sm when applied" do
    ENV["DRY_RUN"] = "false"
    ENV["USER_ID"] = user.id.to_s
    run_task
    board.reload

    expect(board.medium_screen_columns).to eq(8) # 2/3 of 12
    board.board_images.each do |bi|
      bi.reload
      expect(bi.layout["sm"]["x"] + bi.layout["sm"]["w"]).to be <= 4
      expect(bi.layout["md"]).to be_present
    end
  end

  it "leaves columns alone with KEEP_COLUMNS=true but still reflows" do
    ENV["DRY_RUN"] = "false"
    ENV["KEEP_COLUMNS"] = "true"
    ENV["USER_ID"] = user.id.to_s
    run_task
    board.reload

    expect(board.medium_screen_columns).to eq(6) # untouched
    expect(board.board_images.first.reload.layout["sm"]).to be_present
  end

  it "skips a board whose md and sm were hand-customized" do
    board.update!(settings: (board.settings || {}).merge("custom_screen_layouts" => %w[md sm]))
    ENV["DRY_RUN"] = "false"
    ENV["USER_ID"] = user.id.to_s
    run_task

    expect(board.board_images.first.reload.layout["sm"]).to be_nil # never reflowed
  end
end
