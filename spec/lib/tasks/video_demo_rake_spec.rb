require "rails_helper"
require "rake"

RSpec.describe "video_demo rake tasks", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  def run(name)
    task = Rake::Task["video_demo:#{name}"]
    task.reenable
    task.invoke
  end

  before do
    FactoryBot.create(:user, id: User::DEFAULT_ADMIN_ID) unless User.exists?(User::DEFAULT_ADMIN_ID)
    allow(AacWordCategorizer).to receive(:categorize).and_return("noun")
    allow(SaveAudioJob).to receive(:perform_async)
  end

  after do
    ENV.delete("DRY_RUN")
    %w[seed publish unpublish].each { |t| Rake::Task["video_demo:#{t}"].reenable }
  end

  let(:board) { Board.find_by(name: VideoDemoSeeder::BOARD_NAME) }

  describe "seed" do
    before { run(:seed) }

    # published is what makes a predefined admin board public, so seeding it
    # false is what keeps the board reviewable-but-private.
    it "creates the board unpublished so it is not yet public" do
      expect(board).to be_present
      expect(board.published).to be(false)
      expect(board.predefined).to be(true)
      expect(board.user_id).to eq(User::DEFAULT_ADMIN_ID)
      expect(Board.public_boards).not_to include(board)
    end

    it "is viewable by the admin owner but not by a logged-out visitor" do
      admin = User.find(User::DEFAULT_ADMIN_ID)
      expect(board.viewable_by?(admin)).to be(true)
      expect(board.viewable_by?(nil)).to be(false)
    end

    it "adds a tile per curated video, each carrying its youtube config" do
      expect(board.board_images.count).to eq(VideoDemoSeeder::CURATED_VIDEOS.size)
      video = board.board_images.first.data["video"]
      expect(video["source"]).to eq("youtube")
      expect(video["youtube_id"]).to match(/\A[A-Za-z0-9_-]{11}\z/)
    end

    it "does not duplicate the board or its tiles on a second run" do
      run(:seed)

      expect(Board.where(name: VideoDemoSeeder::BOARD_NAME).count).to eq(1)
      expect(board.board_images.count).to eq(VideoDemoSeeder::CURATED_VIDEOS.size)
    end

    it "leaves an already-published board published when re-seeded" do
      board.update!(published: true)
      run(:seed)

      expect(board.reload.published).to be(true)
    end
  end

  describe "publish" do
    it "makes a seeded board public" do
      run(:seed)
      expect(board.published).to be(false)

      run(:publish)

      expect(board.reload.published).to be(true)
      expect(Board.public_boards).to include(board)
    end

    it "refuses to publish a board with no tiles" do
      Board.create!(
        name: VideoDemoSeeder::BOARD_NAME,
        user_id: User::DEFAULT_ADMIN_ID,
        predefined: true,
        published: false,
      )

      run(:publish)

      expect(board.reload.published).to be(false)
    end

    it "does nothing when no board has been seeded" do
      expect { run(:publish) }.not_to raise_error
      expect(board).to be_nil
    end
  end

  describe "unpublish" do
    it "takes a published board back out of public view" do
      run(:seed)
      run(:publish)

      run(:unpublish)

      expect(board.reload.published).to be(false)
      expect(Board.public_boards).not_to include(board)
    end
  end

  describe "DRY_RUN" do
    it "writes nothing to the database" do
      ENV["DRY_RUN"] = "1"
      run(:seed)

      expect(Board.where(name: VideoDemoSeeder::BOARD_NAME)).to be_empty
    end
  end
end
