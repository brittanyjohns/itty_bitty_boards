require "rails_helper"
require "rake"

RSpec.describe "tile_colors rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["tile_colors:repair"] }

  def run(env = {})
    env.each { |k, v| ENV[k] = v }
    task.reenable
    silence_stream { task.invoke }
  ensure
    env.each_key { |k| ENV.delete(k) }
  end

  def silence_stream
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  let(:board) { FactoryBot.create(:board) }
  let(:image) { FactoryBot.create(:image, label: "my turn") }
  let!(:board_image) { FactoryBot.create(:board_image, board: board, image: image) }

  # The live "my turn" shape: classified social (pink), still painted red.
  def make_mismatched!
    image.update_columns(part_of_speech: "social", bg_color: "#FF7070")
    board_image.update_columns(part_of_speech: "social", bg_color: "#FF7070")
  end

  it "is a dry run by default" do
    make_mismatched!

    run

    expect(image.reload.bg_color).to eq("#FF7070")
    expect(board_image.reload.bg_color).to eq("#FF7070")
  end

  it "repaints mismatched rows with WRITE=true" do
    make_mismatched!

    run("WRITE" => "true")

    expect(image.reload.bg_color).to eq("#FF99B8")
    expect(image.part_of_speech).to eq("social")
    expect(board_image.reload.bg_color).to eq("#FF99B8")
    expect(board_image.text_color).to eq("#000000")
  end

  it "is a no-op on a second run" do
    make_mismatched!
    run("WRITE" => "true")
    updated_at = board_image.reload.updated_at

    run("WRITE" => "true")

    expect(board_image.reload.bg_color).to eq("#FF99B8")
    expect(board_image.updated_at).to eq(updated_at)
  end

  it "recolors a per-board override from the tile's own category, never resetting it" do
    image.update_columns(part_of_speech: "verb", bg_color: "#A1F571")
    board_image.update_columns(part_of_speech: "noun", bg_color: "#A1F571")

    run("WRITE" => "true")

    expect(board_image.reload.part_of_speech).to eq("noun")
    expect(board_image.bg_color).to eq("#FFC457")
    expect(image.reload.part_of_speech).to eq("verb")
    expect(image.bg_color).to eq("#A1F571")
  end

  it "leaves an OBF-authored explicit color alone" do
    image.update_columns(part_of_speech: "social", bg_color: "#FF99B8")
    board_image.update_columns(part_of_speech: "social",
                               bg_color: "#123456",
                               data: { "explicit_bg_color" => true })

    run("WRITE" => "true")

    expect(board_image.reload.bg_color).to eq("#123456")
  end

  it "leaves any non-preset color alone even without the flag" do
    board_image.update_columns(part_of_speech: "social", bg_color: "#ABCDEF")

    run("WRITE" => "true")

    expect(board_image.reload.bg_color).to eq("#ABCDEF")
  end

  it "honors SCOPE" do
    make_mismatched!

    run("WRITE" => "true", "SCOPE" => "images")

    expect(image.reload.bg_color).to eq("#FF99B8")
    expect(board_image.reload.bg_color).to eq("#FF7070")
  end
end
