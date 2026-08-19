# frozen_string_literal: true

require "rails_helper"
require "rake"

# Fills data["current_word_list"] on boards that never got one, because
# `set_current_word_list` used to mutate the jsonb hash in place and so never
# persisted. Until they are backfilled, `word_sample` re-queries board_images
# for each of them on every card-list render.
RSpec.describe "board_word_lists:backfill rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["board_word_lists:backfill"] }

  def run_task
    task.reenable
    task.invoke
  end

  around do |example|
    original = ENV.to_hash.slice("DRY_RUN", "USER_ID")
    example.run
    ENV["DRY_RUN"] = original["DRY_RUN"]
    ENV["USER_ID"] = original["USER_ID"]
  end

  before do
    ENV.delete("DRY_RUN")
    ENV.delete("USER_ID")
  end

  let(:user) { FactoryBot.create(:user) }

  def board_missing_word_list
    board = FactoryBot.create(:board, user: user)
    FactoryBot.create(:board_image, board: board)
    board.update_column(:data, (board.data || {}).except("current_word_list"))
    board
  end

  it "fills the word list when applied" do
    board = board_missing_word_list
    ENV["DRY_RUN"] = "false"

    expect { run_task }.to output(/filled: \d+/).to_stdout

    expect(board.reload.data["current_word_list"]).to be_present
  end

  it "changes nothing on a dry run" do
    board = board_missing_word_list

    expect { run_task }.to output(/would fill/).to_stdout

    expect(board.reload.data["current_word_list"]).to be_nil
  end

  it "leaves a board with no tiles alone" do
    empty = FactoryBot.create(:board, user: user)
    empty.update_column(:data, (empty.data || {}).except("current_word_list"))
    ENV["DRY_RUN"] = "false"

    expect { run_task }.to output(/skipped \(no tiles\)/).to_stdout

    expect(empty.reload.data["current_word_list"]).to be_nil
  end

  it "honors USER_ID scoping" do
    mine = board_missing_word_list
    other = FactoryBot.create(:board, user: FactoryBot.create(:user))
    FactoryBot.create(:board_image, board: other)
    other.update_column(:data, (other.data || {}).except("current_word_list"))

    ENV["DRY_RUN"] = "false"
    ENV["USER_ID"] = user.id.to_s
    run_task

    expect(mine.reload.data["current_word_list"]).to be_present
    expect(other.reload.data["current_word_list"]).to be_nil
  end
end
