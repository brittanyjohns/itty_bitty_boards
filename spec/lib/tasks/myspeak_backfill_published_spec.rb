require "rails_helper"
require "rake"

# The repair sweep for boards starred onto a MySpeak page before publishing
# descended the folder-tile graph: the card is published and works, and every
# folder tile on it 404s for a visitor.
RSpec.describe "myspeak:backfill_published rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["myspeak:backfill_published"] }

  def run_task
    task.reenable
    task.invoke
  end

  around do |example|
    original = ENV["APPLY"]
    example.run
    ENV["APPLY"] = original
  end

  let(:owner) { FactoryBot.create(:user) }
  let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner) }

  def link(from, to)
    FactoryBot.create(:board_image, board: from, predictive_board_id: to.id)
  end

  # A published, starred board with one private page behind a folder tile.
  # `update_column` so ChildBoard's own after_save publisher doesn't repair the
  # tree before the task gets a look at it.
  def broken_tree!(page_published: false)
    root = FactoryBot.create(:board, user: owner, name: "Home", published: true)
    page = FactoryBot.create(:board, user: owner, name: "Food", published: page_published)
    link(root, page)
    cb = ChildBoard.create!(child_account: child, board: root)
    cb.update_column(:favorite, true)
    [root, page]
  end

  it "reports what it would publish and writes nothing by default" do
    _root, page = broken_tree!

    expect { run_task }.to output(/would publish 1 page\(s\) under 'Home'/).to_stdout
    expect(page.reload.published).to be_falsey
  end

  it "publishes the pages behind the board with APPLY=1" do
    _root, page = broken_tree!
    ENV["APPLY"] = "1"

    expect { run_task }.to output(/APPLIED/).to_stdout
    expect(page.reload.published).to be true
  end

  it "reports nothing on a healthy tree" do
    broken_tree!(page_published: true)

    expect { run_task }.to output(/0 need repair/).to_stdout
  end

  # An unpublished favorite is a different bug — typically a board owned by
  # someone other than the page owner, which MySpeakPublisher deliberately
  # leaves private. Publishing it here would make that consent decision.
  it "skips a starred board that is not itself published" do
    root = FactoryBot.create(:board, user: owner, name: "Home", published: false)
    page = FactoryBot.create(:board, user: owner, name: "Food", published: false)
    link(root, page)
    ChildBoard.create!(child_account: child, board: root).update_column(:favorite, true)

    run_task
    expect(page.reload.published).to be_falsey
  end

  it "skips a starred board owned by someone other than the page owner" do
    theirs = FactoryBot.create(:board, user: FactoryBot.create(:user), name: "SLP board",
                                       published: true)
    page = FactoryBot.create(:board, user: theirs.user, name: "Food", published: false)
    link(theirs, page)
    ChildBoard.create!(child_account: child, board: theirs).update_column(:favorite, true)
    ENV["APPLY"] = "1"

    run_task
    expect(page.reload.published).to be_falsey
  end

  it "ignores a board that is attached but not starred" do
    root = FactoryBot.create(:board, user: owner, name: "Home", published: true)
    page = FactoryBot.create(:board, user: owner, name: "Food", published: false)
    link(root, page)
    ChildBoard.create!(child_account: child, board: root, favorite: false)
    ENV["APPLY"] = "1"

    run_task
    expect(page.reload.published).to be_falsey
  end
end
