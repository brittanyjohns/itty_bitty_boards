# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "board_covers:render_missing rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["board_covers:render_missing"] }

  def run_task
    task.reenable
    task.invoke
  end

  around do |example|
    original = ENV.to_hash.slice("DRY_RUN", "USER_ID", "LIMIT")
    example.run
    %w[DRY_RUN USER_ID LIMIT].each { |k| ENV[k] = original[k] }
  end

  let(:user) { create(:user) }

  # A board with tiles and no cover — the backlog this task exists to clear.
  let!(:uncovered) do
    board = create(:board, user: user, name: "Uncovered")
    create(:board_image, board: board, image: create(:image, user: user))
    board.update_column(:display_image_url, nil)
    board
  end

  before { ENV["DRY_RUN"] = "false" }

  it "renders a board that has tiles but no cover" do
    run_task
    expect(uncovered.reload.settings["preview_status"]).to eq("queued")
  end

  it "skips a board that already has a cover" do
    covered = create(:board, user: user, name: "Covered")
    create(:board_image, board: covered, image: create(:image, user: user))
    covered.update_column(:display_image_url, "https://cdn.example.com/cover.png")

    run_task
    expect(covered.reload.settings["preview_status"]).to be_nil
  end

  it "skips a board with no tiles" do
    empty = create(:board, user: user, name: "Empty")
    empty.update_column(:display_image_url, nil)

    run_task
    expect(empty.reload.settings["preview_status"]).to be_nil
  end

  # A set renders ONE preview (the root); every other page is thumbnailed from
  # the folder tile that opens it, so enqueuing sub-pages is queue volume for a
  # render that gets discarded.
  it "skips builder_child sub-boards" do
    child = create(:board, user: user, name: "Sub", settings: { "builder_child" => true })
    create(:board_image, board: child, image: create(:image, user: user))
    child.update_column(:display_image_url, nil)

    run_task
    expect(child.reload.settings["preview_status"]).to be_nil
  end

  # boards.settings has no NOT NULL constraint, and `NULL @> x` is NULL — so a
  # negated inline containment check would drop exactly these rows.
  it "still selects a board whose settings are nil" do
    uncovered.update_column(:settings, nil)

    run_task
    expect(uncovered.reload.settings["preview_status"]).to eq("queued")
  end

  it "enqueues nothing on a dry run" do
    ENV["DRY_RUN"] = "true"

    run_task
    expect(uncovered.reload.settings["preview_status"]).to be_nil
  end

  it "stops at LIMIT" do
    other = create(:board, user: user, name: "Second")
    create(:board_image, board: other, image: create(:image, user: user))
    other.update_column(:display_image_url, nil)
    ENV["LIMIT"] = "1"

    run_task

    queued = [uncovered, other].count { |b| b.reload.settings.to_h["preview_status"] == "queued" }
    expect(queued).to eq(1)
  end
end
