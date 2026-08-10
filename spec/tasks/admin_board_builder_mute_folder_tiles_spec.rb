require "rails_helper"
require "rake"

RSpec.describe "admin_board_builder:mute_folder_tiles" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("admin_board_builder:mute_folder_tiles")
  end

  let(:task) { Rake::Task["admin_board_builder:mute_folder_tiles"] }
  let(:user) { create(:user) }
  let(:builder_settings) { { AdminBoardBuild::BUILDER_SETTING => true } }
  let!(:root) do
    create(:board, user: user, name: "Snack Time", settings: builder_settings.merge("builder_root" => true))
  end
  let!(:food) do
    create(:board, user: user, name: "Food", settings: builder_settings.merge("builder_child" => true))
  end

  def tile(board, label, target: nil)
    board_image = create(:board_image, board: board, image: create(:image, label: label, user_id: user.id))
    board_image.update_columns(label: label, predictive_board_id: target)
    board_image
  end

  let!(:folder) { tile(root, "food", target: food.id) }
  let!(:word) { tile(root, "want") }
  let!(:back) { tile(food, "back", target: root.id) }

  before { task.reenable }

  after { ENV.delete("DRY_RUN") }

  it "writes nothing by default" do
    expect { task.invoke }.to output(/Dry run only — 2 linked tile/).to_stdout

    expect(folder.reload.data["mute_name"]).to be_nil
    expect(back.reload.data["mute_name"]).to be_nil
  end

  # A door isn't a word: opening the food page shouldn't speak "food", and the
  # way back out isn't a word either.
  it "mutes every linked tile with DRY_RUN=false and leaves word tiles alone" do
    ENV["DRY_RUN"] = "false"

    expect { task.invoke }.to output(/Muted 2 linked tile\(s\) across 2 board\(s\)/).to_stdout

    expect(folder.reload.data["mute_name"]).to be(true)
    expect(back.reload.data["mute_name"]).to be(true)
    expect(word.reload.data["mute_name"]).to be_nil
  end

  # builder_boards is the rail every admin action on these boards runs on; a
  # board this page didn't create is out of reach even when it has folder tiles.
  it "leaves boards the admin builder didn't create alone" do
    other_root = create(:board, user: user, name: "Someone else's board")
    other_folder = tile(other_root, "food", target: food.id)
    ENV["DRY_RUN"] = "false"

    expect { task.invoke }.to output(/Muted 2 linked tile/).to_stdout

    expect(other_folder.reload.data["mute_name"]).to be_nil
  end

  it "scopes to one build with BUILD_ID" do
    build = AdminBoardBuild.create!(
      created_by: user, name: "Snack Time", voice: "polly:kevin",
      columns_count: 2, tile_count: 4, board: root,
      art_report: { "boards" => { "root" => root.id } },
    )
    ENV["DRY_RUN"] = "false"
    ENV["BUILD_ID"] = build.id.to_s

    expect { task.invoke }.to output(/Muted 1 linked tile\(s\) across 1 board\(s\)/).to_stdout

    expect(folder.reload.data["mute_name"]).to be(true)
    expect(back.reload.data["mute_name"]).to be_nil
  ensure
    ENV.delete("BUILD_ID")
  end

  it "is a no-op on a tile that is already muted" do
    folder.update_column(:data, { "mute_name" => true })
    ENV["DRY_RUN"] = "false"

    expect { task.invoke }.to output(/Muted 1 linked tile\(s\) across 1 board\(s\)/).to_stdout
  end
end
