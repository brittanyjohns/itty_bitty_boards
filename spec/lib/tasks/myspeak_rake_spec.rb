require "rails_helper"
require "rake"

RSpec.describe "myspeak rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["myspeak:tag_recommended"] }

  def run_task
    task.reenable
    task.invoke
  end

  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  def myspeak_board(name, tags)
    create(:board, user: admin, name: name, predefined: true, published: true, tags: tags)
  end

  describe "myspeak:tag_recommended" do
    it "adds myspeak-recommended to the Core Words board, keeping myspeak" do
      board = myspeak_board("Core Words", ["myspeak"])

      run_task

      expect(board.reload.tags).to include("myspeak", "myspeak-recommended")
    end

    it "is idempotent — re-running adds no duplicate tag" do
      board = myspeak_board("Core Words", ["myspeak", "myspeak-recommended"])

      run_task

      expect(board.reload.tags.count("myspeak-recommended")).to eq(1)
    end

    it "matches the board name case-insensitively" do
      board = myspeak_board("core words", ["myspeak"])

      run_task

      expect(board.reload.tags).to include("myspeak-recommended")
    end

    it "no-ops when no public MySpeak Core Words board exists" do
      other = myspeak_board("Animals", ["myspeak"])

      expect { run_task }.not_to raise_error
      expect(other.reload.tags).not_to include("myspeak-recommended")
    end
  end
end
