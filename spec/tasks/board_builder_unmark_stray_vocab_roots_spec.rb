require "rails_helper"
require "rake"

RSpec.describe "board_builder:unmark_stray_vocab_roots" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("board_builder:unmark_stray_vocab_roots")
  end

  let(:task) { Rake::Task["board_builder:unmark_stray_vocab_roots"] }

  let(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  # What `vocab_sets:seed` produces: admin-owned and predefined.
  let!(:seed) do
    board = create(:board, user: admin, name: "Core 84", predefined: true, published: true)
    Boards::RobustSets.mark_root!(board, "core-84")
  end

  # What a clone made before Board#clone_with_images stripped the markers looks
  # like: same two keys, but not predefined.
  let!(:stray) do
    board = create(:board, user: admin, name: "Classroom — Core Words Poster",
                           predefined: false, published: true)
    board.update_columns(settings: { Boards::RobustSets::ROOT_MARKER => true,
                                     Boards::RobustSets::SLUG_MARKER => "core-84" })
    board
  end

  before { task.reenable }
  after { ENV.delete("DRY_RUN") }

  def markers(board)
    settings = board.reload.settings || {}
    settings.values_at(Boards::RobustSets::ROOT_MARKER, Boards::RobustSets::SLUG_MARKER)
  end

  it "reports without writing by default" do
    expect { task.invoke }.to output(/Dry run only.*1 stray root/m).to_stdout

    expect(markers(stray)).to eq([true, "core-84"])
  end

  it "unmarks the stray with DRY_RUN=false and leaves the real seed alone" do
    ENV["DRY_RUN"] = "false"

    expect { task.invoke }.to output(/Unmarked 1 stray root/).to_stdout

    expect(markers(stray)).to eq([nil, nil])
    expect(markers(seed)).to eq([true, "core-84"])
    expect(Boards::RobustSets.find_root("core-84")).to eq(seed)
  end

  it "never renames, unpublishes, or destroys a board" do
    ENV["DRY_RUN"] = "false"

    expect { task.invoke }.to output(/Unmarked/).to_stdout

    expect(stray.reload.name).to eq("Classroom — Core Words Poster")
    expect(stray.published).to be(true)
    expect(Board.exists?(stray.id)).to be(true)
  end

  it "flags the built sets that took their name from the stray" do
    user = create(:user)
    create(:board, user: user, name: "Classroom — Core Words Poster",
                   settings: { "builder_root" => true })
    create(:board_group, user: user, name: "Classroom — Core Words Poster", builder: true)

    expect { task.invoke }.to output(/Built sets named after a stray.*NOT renamed/m).to_stdout
  end

  it "flags that unmarking admits a published admin board to the printables dashboard" do
    expect { task.invoke }.to output(/admit them to Board.admin_owned_boards/).to_stdout
  end

  it "does nothing when only the real seed is marked" do
    stray.update_columns(settings: {})
    task.reenable

    expect { task.invoke }.to output(/Nothing to unmark/).to_stdout
    expect(markers(seed)).to eq([true, "core-84"])
  end
end
