require "rails_helper"
require "rake"

RSpec.describe "myspeak:stale_starter_clones rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["myspeak:stale_starter_clones"] }

  def run_task
    task.reenable
    task.invoke
  end

  let(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) ||
      FactoryBot.create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end
  let(:owner) { FactoryBot.create(:user) }
  let(:child) { FactoryBot.create(:child_account, user: owner, owner: owner) }
  let!(:starter) { FactoryBot.create(:board, user: admin, predefined: true, published: true) }

  # The shape the wizard used to mint: an invisible template clone of an admin
  # starter, favorited onto the communicator's safety page.
  def stale_clone!(favorite: true, is_template: true, created_by: owner, board_owner: owner)
    Profile.create!(profileable: child, username: child.username) unless child.profile
    clone = FactoryBot.create(:board, user: board_owner, is_template: is_template)
    ChildBoard.create!(child_account: child, board: clone, original_board: starter,
                       created_by_id: created_by.id, favorite: favorite)
  end

  it "reports a stale wizard clone" do
    cb = stale_clone!
    expect { run_task }.to output(/1 candidate/).to_stdout
    expect { run_task }.to output(/child_board=#{cb.id}/).to_stdout
  end

  it "writes nothing" do
    cb = stale_clone!
    expect { run_task }.to output.to_stdout
    expect(cb.reload.favorite).to be true
    expect(cb.board.reload.is_template).to be true
  end

  it "ignores an SLP-assigned board (attached by someone other than the page owner)" do
    slp = FactoryBot.create(:user)
    stale_clone!(created_by: slp, board_owner: slp)
    expect { run_task }.to output(/0 candidate/).to_stdout
  end

  it "ignores an unfavorited assignment" do
    stale_clone!(favorite: false)
    expect { run_task }.to output(/0 candidate/).to_stdout
  end

  it "ignores a board that is already visible to its owner" do
    stale_clone!(is_template: false)
    expect { run_task }.to output(/0 candidate/).to_stdout
  end
end
