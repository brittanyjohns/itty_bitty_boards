require "rails_helper"
require "rake"

RSpec.describe "board_builder:sync_nav_rows" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("board_builder:sync_nav_rows")
  end

  let(:task) { Rake::Task["board_builder:sync_nav_rows"] }
  let(:user) { create(:user) }
  let!(:root) do
    create(:board, user: user, name: "Core 60", large_screen_columns: 4,
                   settings: { "builder_root" => true })
  end
  let!(:food) { create(:board, user: user, name: "Food", large_screen_columns: 4) }

  def tile(board, label, x:, y:, position:, target: nil)
    bi = create(:board_image, board: board, position: position,
                              image: create(:image, label: label, user_id: user.id))
    bi.update_columns(label: label, predictive_board_id: target)
    bi.update_column(:layout, { "lg" => { "i" => bi.id.to_s, "x" => x, "y" => y, "w" => 1, "h" => 1 } })
    bi
  end

  before do
    tile(root, "I", x: 0, y: 0, position: 1)
    tile(root, "this", x: 0, y: 1, position: 2)
    tile(root, "Food", x: 1, y: 1, position: 3, target: food.id)
    task.reenable
  end

  after { ENV.delete("DRY_RUN") }

  it "writes nothing by default" do
    expect { task.invoke }.to output(/Dry run only/).to_stdout
    expect(food.board_images.reload).to be_empty
  end

  it "applies with DRY_RUN=false" do
    ENV["DRY_RUN"] = "false"

    expect { task.invoke }.to output(/Synced/).to_stdout

    labels = food.board_images.reload.map(&:label)
    expect(labels).to include("Food", "this")

    self_tile = food.board_images.find { |bi| bi.label == "Food" }
    expect(self_tile.predictive_board_id).to eq(root.id)
  end

  it "skips sets owned by another user when USER_ID is set" do
    ENV["DRY_RUN"] = "false"
    ENV["USER_ID"] = create(:user).id.to_s

    task.invoke

    expect(food.board_images.reload).to be_empty
  ensure
    ENV.delete("USER_ID")
  end
end
