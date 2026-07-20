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
    %w[BOARD DRY_RUN].each { |k| ENV.delete(k) }
    %w[seed publish unpublish].each { |t| Rake::Task["video_demo:#{t}"].reenable }
  end

  def board_for(key)
    Board.find_by(name: VideoDemoSeeder.config_for(key)[:name])
  end

  describe "seed" do
    it "seeds every configured board when BOARD is not given" do
      run(:seed)

      VideoDemoSeeder.board_keys.each do |key|
        cfg = VideoDemoSeeder.config_for(key)
        board = board_for(key)
        expect(board).to be_present, "expected the #{key} board to exist"
        expect(board.board_images.count).to eq(cfg[:videos].size)
      end
    end

    it "seeds only the named board when BOARD is given" do
      ENV["BOARD"] = "asl"
      run(:seed)

      expect(board_for("asl")).to be_present
      expect(board_for("songs")).to be_nil
    end

    it "raises on an unknown BOARD rather than silently seeding nothing" do
      ENV["BOARD"] = "nope"

      expect { run(:seed) }.to raise_error(/unknown BOARD/)
      expect(Board.count).to eq(0)
    end

    # published is what makes a predefined admin board public, so seeding it
    # false is what keeps these boards reviewable-but-private.
    it "creates every board unpublished and out of public view" do
      run(:seed)

      VideoDemoSeeder.board_keys.each do |key|
        board = board_for(key)
        expect(board.published).to be(false)
        expect(Board.public_boards).not_to include(board)
        expect(board.viewable_by?(nil)).to be(false)
        expect(board.viewable_by?(User.find(User::DEFAULT_ADMIN_ID))).to be(true)
      end
    end

    it "gives every tile a valid youtube video config" do
      run(:seed)

      VideoDemoSeeder.board_keys.each do |key|
        board_for(key).board_images.each do |bi|
          video = bi.data["video"]
          expect(video["source"]).to eq("youtube")
          expect(video["youtube_id"]).to match(/\A[A-Za-z0-9_-]{11}\z/)
        end
      end
    end

    it "does not duplicate boards or tiles on a second run" do
      run(:seed)
      run(:seed)

      VideoDemoSeeder.board_keys.each do |key|
        cfg = VideoDemoSeeder.config_for(key)
        expect(Board.where(name: cfg[:name]).count).to eq(1)
        expect(board_for(key).board_images.count).to eq(cfg[:videos].size)
      end
    end

    it "leaves an already-published board published when re-seeded" do
      run(:seed)
      board_for("asl").update!(published: true)
      run(:seed)

      expect(board_for("asl").reload.published).to be(true)
    end

    it "writes nothing under DRY_RUN" do
      ENV["DRY_RUN"] = "1"
      run(:seed)

      expect(Board.count).to eq(0)
    end
  end

  describe "publish" do
    before { run(:seed) }

    it "makes the named board public and leaves the others alone" do
      ENV["BOARD"] = "asl"
      run(:publish)

      expect(board_for("asl").reload.published).to be(true)
      expect(Board.public_boards).to include(board_for("asl"))
      expect(board_for("songs").reload.published).to be(false)
    end

    # Publishing is public-facing, so it must never happen to an unnamed board.
    it "refuses to publish anything when BOARD is omitted" do
      run(:publish)

      VideoDemoSeeder.board_keys.each do |key|
        expect(board_for(key).reload.published).to be(false)
      end
    end

    it "refuses to publish a board with no tiles" do
      board_for("asl").board_images.destroy_all
      ENV["BOARD"] = "asl"
      run(:publish)

      expect(board_for("asl").reload.published).to be(false)
    end
  end

  describe "unpublish" do
    it "takes a published board back out of public view" do
      run(:seed)
      ENV["BOARD"] = "asl"
      run(:publish)
      run(:unpublish)

      expect(board_for("asl").reload.published).to be(false)
      expect(Board.public_boards).not_to include(board_for("asl"))
    end

    it "refuses to act when BOARD is omitted" do
      run(:seed)
      board_for("asl").update!(published: true)
      run(:unpublish)

      expect(board_for("asl").reload.published).to be(true)
    end
  end
end
