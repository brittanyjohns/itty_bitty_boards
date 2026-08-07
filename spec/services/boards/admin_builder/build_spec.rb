require "rails_helper"

RSpec.describe Boards::AdminBuilder::Build do
  let!(:admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }
  let(:requester) { create(:admin_user) }

  # "Has art" is a Doc row — Boards::ImageResolver and `where.missing(:docs)`
  # both key on that, not on an attached blob. No attachment here on purpose:
  # ActiveStorage defers the upload to after_commit, and this service opens its
  # own transaction, so attaching in setup makes the deferred upload fire mid-
  # build against an already-consumed IO.
  def image_with_art(label:)
    image = Image.create!(label: label, user_id: admin.id)
    image.docs.create!(user_id: admin.id, source_type: "OpenAI", raw: label)
    image
  end

  def build_record(tiles:, columns: 2, rows: 2, **overrides)
    AdminBoardBuild.create!(
      {
        created_by: requester,
        name: "Playground",
        topic: "the playground",
        voice: "polly:kevin",
        columns_count: columns,
        rows_count: rows,
        plan: { "tiles" => tiles },
      }.merge(overrides),
    )
  end

  def four_tiles
    [
      { "label" => "i", "part_of_speech" => "pronoun" },
      { "label" => "want", "part_of_speech" => "verb" },
      { "label" => "more", "part_of_speech" => "important_function" },
      { "label" => "swing", "part_of_speech" => "noun" },
    ]
  end

  around { |example| Sidekiq::Testing.fake! { example.run } }
  before { GenerateImagesJob.jobs.clear }

  describe "the board it writes" do
    let(:build) { build_record(tiles: four_tiles) }

    it "creates an unpublished board owned by the default admin and marked as ours" do
      board = described_class.new(admin_board_build: build).call

      expect(board.published).to be(false)
      expect(board.user_id).to eq(admin.id)
      expect(board.predefined).to be(true)
      expect(board.board_type).to eq("static")
      expect(board.settings["admin_builder"]).to be(true)
      expect(board.settings["disable_scroll"]).to be(true)
      expect(board.voice).to eq("polly:kevin")
      expect(build.reload.status).to eq("complete")
      expect(build.board_id).to eq(board.id)
    end

    # Hand-setting md/sm writes settings["custom_screen_layouts"] and
    # permanently stops reflow — only the authored lg count may be set.
    it "sets only the large column count and lets md/sm derive from it" do
      board = described_class.new(admin_board_build: build_record(tiles: four_tiles, columns: 6, rows: 1)).call

      expect(board.large_screen_columns).to eq(6)
      expect(board.medium_screen_columns).to eq(Boards::ScreenColumns.derive(6, "md"))
      expect(board.small_screen_columns).to eq(Boards::ScreenColumns.derive(6, "sm"))
      expect(Array(board.settings["custom_screen_layouts"])).to be_empty
    end

    it "lays tiles out in authored reading order" do
      board = described_class.new(admin_board_build: build).call

      expect(board.board_images.order(:position).map(&:label)).to eq(%w[i want more swing])
    end

    it "applies the authored part of speech, which is what lands the Fitzgerald colour" do
      board = described_class.new(admin_board_build: build).call
      tile = board.board_images.order(:position).find { |bi| bi.label == "want" }

      expect(tile.part_of_speech).to eq("verb")
      expect(tile.bg_color).to eq(ColorHelper::PRESET_HEX["green"])
    end

    it "uses the tile text when a display_label is authored" do
      tiles = four_tiles
      tiles[0] = tiles[0].merge("display_label" => "Me")
      board = described_class.new(admin_board_build: build_record(tiles: tiles)).call

      expect(board.board_images.order(:position).first.display_label).to eq("Me")
    end

    it "surfaces the final slug, which a hex suffix may have changed" do
      Board.create!(name: "Playground", slug: "playground", user: admin)
      board = described_class.new(admin_board_build: build).call

      expect(board.slug).to start_with("playground")
      expect(build.reload.art_report["slug"]).to eq(board.slug)
    end
  end

  describe "art" do
    it "reuses library art and doesn't queue generation for a covered label" do
      four_tiles.each { |tile| image_with_art(label: tile["label"]) }
      build = build_record(tiles: four_tiles)

      described_class.new(admin_board_build: build).call

      expect(GenerateImagesJob.jobs).to be_empty
      expect(build.reload.art_report["coverage_pct"]).to eq(100)
      expect(build.art_report["missing_labels"]).to be_empty
    end

    it "creates a blank image for an uncovered label and queues generation in slices of 3" do
      build = build_record(tiles: four_tiles)

      expect { described_class.new(admin_board_build: build).call }.to change(Image, :count).by(4)

      queued = GenerateImagesJob.jobs.map { |job| job["args"].first }
      expect(queued.map(&:size)).to eq([3, 1])
      expect(queued.flatten.size).to eq(4)
      expect(build.reload.art_report["coverage_pct"]).to eq(0)
      expect(build.art_report["missing_labels"]).to match_array(%w[i want more swing])
    end

    # The topic is what keeps "swing" on a playground board from coming back as
    # a mood swing. image_prompt carries intent only — Images::PromptBuilder
    # composes the house envelope at generation time.
    it "seeds a topic-aware prompt on generated images without baking in the house style" do
      described_class.new(admin_board_build: build_record(tiles: four_tiles)).call

      prompt = Image.find_by(label: "swing").image_prompt
      expect(prompt).to eq("swing in the context of the playground")
      expect(prompt).not_to include("flat vector")
    end

    it "falls back to a bare label when no topic was given" do
      described_class.new(admin_board_build: build_record(tiles: four_tiles, topic: nil)).call

      expect(Image.find_by(label: "swing").image_prompt).to eq("swing")
    end

    # Sidekiq can pick a job up before the rows it references exist, so
    # generation must be queued after the transaction closes. The build's
    # board_id is only assigned once it has, which makes it a usable probe.
    it "queues generation only after the transaction has closed" do
      build = build_record(tiles: four_tiles)
      board_id_when_queued = :never_queued
      allow(GenerateImagesJob).to receive(:perform_async) do |_ids, board_id|
        board_id_when_queued = build.reload.board_id
        expect(Board.find_by(id: board_id)).to be_present
      end

      described_class.new(admin_board_build: build).call

      expect(board_id_when_queued).to eq(build.reload.board_id)
      expect(board_id_when_queued).to be_present
    end
  end

  describe "failure" do
    it "records the error, writes no board, and re-raises so Sidekiq retries" do
      build = build_record(tiles: four_tiles)
      allow(Board).to receive(:new).and_raise(ActiveRecord::RecordInvalid.new(Board.new))

      expect { described_class.new(admin_board_build: build).call }.to raise_error(ActiveRecord::RecordInvalid)

      expect(build.reload.status).to eq("failed")
      expect(build.error_message).to be_present
      expect(build.board_id).to be_nil
      expect(Board.where(name: "Playground")).to be_empty
    end

    it "aborts the whole build when a tile can't be added, leaving no short board" do
      build = build_record(tiles: four_tiles)
      allow_any_instance_of(Board).to receive(:add_image).and_return(nil)

      expect { described_class.new(admin_board_build: build).call }
        .to raise_error(Boards::AdminBuilder::Build::BuildError, /could not add a tile/)

      expect(Board.where(name: "Playground")).to be_empty
      expect(build.reload.status).to eq("failed")
    end

    it "is a no-op when the build already produced a board" do
      build = build_record(tiles: four_tiles)
      board = described_class.new(admin_board_build: build).call

      expect { described_class.new(admin_board_build: build.reload).call }.not_to change(Board, :count)
      expect(build.reload.board_id).to eq(board.id)
    end
  end
end
