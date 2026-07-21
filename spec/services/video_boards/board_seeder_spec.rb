require "rails_helper"

RSpec.describe VideoBoards::BoardSeeder do
  let(:admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  def config(overrides = {})
    {
      name: "Seeder Spec Board",
      description: "A board of videos",
      tags: %w[videos demo],
      columns: 3,
      videos: [
        { label: "more", youtube_id: "34CBy8zipZQ", range: {} },
        { label: "help", youtube_id: "XM1nr6IkcBE", range: {} },
      ],
    }.merge(overrides)
  end

  describe ".build_board!" do
    it "creates an unpublished predefined board owned by the admin, with a video tile per entry" do
      board = described_class.build_board!(config, admin: admin)

      expect(board).to be_persisted
      expect(board.published).to be(false)
      expect(board.predefined).to be(true)
      expect(board.user_id).to eq(admin.id)
      expect(board.number_of_columns).to eq(3)
      expect(board.small_screen_columns).to eq(3)
      expect(board.large_screen_columns).to eq(3)
      expect(board.tags).to eq(%w[videos demo])
      expect(board.slug).to be_present

      ids = board.board_images.map { |bi| bi.data.dig("video", "youtube_id") }
      expect(ids).to contain_exactly("34CBy8zipZQ", "XM1nr6IkcBE")
    end

    it "stores trim points when a range is supplied" do
      cfg = config(videos: [{ label: "more", youtube_id: "34CBy8zipZQ",
                              range: { "start_seconds" => 45, "end_seconds" => 72 } }])
      board = described_class.build_board!(cfg, admin: admin)

      video = board.board_images.first.data["video"]
      expect(video["start_seconds"]).to eq(45)
      expect(video["end_seconds"]).to eq(72)
    end

    it "stores only the bound that was supplied" do
      cfg = config(videos: [{ label: "more", youtube_id: "34CBy8zipZQ", range: { "start_seconds" => 10 } }])
      board = described_class.build_board!(cfg, admin: admin)

      video = board.board_images.first.data["video"]
      expect(video["start_seconds"]).to eq(10)
      expect(video).not_to have_key("end_seconds")
    end

    it "merges settings from the config" do
      board = described_class.build_board!(config(settings: { "video_seeder" => true }), admin: admin)
      expect(board.settings["video_seeder"]).to be(true)
    end

    it "reuses an existing public image for a label instead of creating a duplicate" do
      existing = create(:image, label: "more", is_private: false, user_id: nil)
      board = described_class.build_board!(config, admin: admin)

      expect(board.board_images.map(&:image_id)).to include(existing.id)
    end

    it "is idempotent by name — a re-run adds no duplicate tiles and never publishes" do
      board = described_class.build_board!(config, admin: admin)
      expect(board.board_images.count).to eq(2)

      again = described_class.build_board!(config, admin: admin)

      expect(again.id).to eq(board.id)
      expect(again.board_images.count).to eq(2)
      expect(again.published).to be(false)
    end

    it "does not un-publish a board that was already reviewed and published" do
      board = described_class.build_board!(config, admin: admin)
      board.update!(published: true)

      again = described_class.build_board!(config, admin: admin)
      expect(again.reload.published).to be(true)
    end
  end

  describe ".suggested_columns" do
    it "lands on a roughly square grid" do
      expect(described_class.suggested_columns(3)).to eq(2)
      expect(described_class.suggested_columns(8)).to eq(3)
      expect(described_class.suggested_columns(12)).to eq(4)
      expect(described_class.suggested_columns(20)).to eq(5)
      expect(described_class.suggested_columns(40)).to eq(6)
    end
  end
end
