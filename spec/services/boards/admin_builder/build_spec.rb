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

  def build_record(tiles:, columns: 2, tile_count: 4, children: [], **overrides)
    AdminBoardBuild.create!(
      {
        created_by: requester,
        name: "Playground",
        topic: "the playground",
        voice: "polly:kevin",
        columns_count: columns,
        tile_count: tile_count,
        plan: { "tiles" => tiles, "children" => children },
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
      board = described_class.new(admin_board_build: build_record(tiles: four_tiles, columns: 6, tile_count: 6)).call

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

  describe "a linked set" do
    def root_with_folder
      [
        { "label" => "i", "part_of_speech" => "pronoun" },
        { "label" => "want", "part_of_speech" => "verb" },
        { "label" => "more", "part_of_speech" => "important_function" },
        { "label" => "Food", "part_of_speech" => "noun", "links_to" => "food" },
      ]
    end

    def food_page(tiles: nil)
      {
        "key" => "food", "name" => "Food",
        "tiles" => tiles || [
          { "label" => "apple", "part_of_speech" => "noun" },
          { "label" => "banana", "part_of_speech" => "noun" },
          { "label" => "hungry", "part_of_speech" => "adjective" },
          { "label" => "eat", "part_of_speech" => "verb" },
        ],
      }
    end

    let(:build) { build_record(tiles: root_with_folder, children: [food_page]) }

    it "creates every page and points the folder tile at its child" do
      root = described_class.new(admin_board_build: build).call

      expect(Board.count).to eq(2)
      folder = root.board_images.order(:position).find { |bi| bi.label == "food" }
      child = Board.find(folder.predictive_board_id)

      expect(child.name).to eq("Food")
      expect(child.board_images.order(:position).map(&:label)).to eq(%w[apple banana hungry eat])
    end

    it "records every page on the build so publish and show can reach them" do
      root = described_class.new(admin_board_build: build).call
      boards = build.reload.art_report["boards"]

      expect(boards.keys).to contain_exactly(Boards::AdminBuilder::Plan::ROOT_KEY, "food")
      expect(boards[Boards::AdminBuilder::Plan::ROOT_KEY]).to eq(root.id)
      expect(build.set_boards.map(&:id)).to eq([root.id, boards["food"]])
    end

    # Only the root belongs in the public catalogue — Board.public_boards keys
    # on `predefined`, and a set whose folder pages showed up there as
    # standalone boards would bury the board they belong to.
    it "marks the root predefined and the pages not" do
      root = described_class.new(admin_board_build: build).call
      child = build.reload.set_boards.last

      expect(root.predefined).to be(true)
      expect(child.predefined).to be(false)
      expect(child.settings["admin_builder"]).to be(true)
      expect(child.settings["builder_child"]).to be(true)
      expect(root.settings["builder_root"]).to be(true)
    end

    it "gives every page the root's grid" do
      root = described_class.new(admin_board_build: build_record(
        tiles: root_with_folder, columns: 4, tile_count: 4, children: [food_page],
      )).call
      child = Board.find(root.board_images.find { |bi| bi.predictive_board_id }.predictive_board_id)

      expect(child.large_screen_columns).to eq(4)
      expect(child.medium_screen_columns).to eq(Boards::ScreenColumns.derive(4, "md"))
    end

    it "lets a page override the grid when one was authored" do
      root = described_class.new(admin_board_build: build_record(
        tiles: root_with_folder,
        children: [food_page.merge("columns" => 2, "tile_count" => 4)],
      )).call
      child = Board.find(root.board_images.find { |bi| bi.predictive_board_id }.predictive_board_id)

      expect(child.large_screen_columns).to eq(2)
    end

    # Cycles are normal: a page almost always carries a "back to home" tile.
    # Every board row exists before any link is set, so this needs no ordering.
    it "wires a page's back-link to the root" do
      back = food_page(tiles: [
        { "label" => "apple", "part_of_speech" => "noun" },
        { "label" => "banana", "part_of_speech" => "noun" },
        { "label" => "hungry", "part_of_speech" => "adjective" },
        { "label" => "back", "part_of_speech" => "social", "links_to" => Boards::AdminBuilder::Plan::ROOT_KEY },
      ])
      root = described_class.new(admin_board_build: build_record(tiles: root_with_folder, children: [back])).call
      child = Board.find(root.board_images.find { |bi| bi.predictive_board_id }.predictive_board_id)

      expect(child.board_images.find { |bi| bi.label == "back" }.predictive_board_id).to eq(root.id)
    end

    it "wires two pages that link to each other" do
      root_tiles = [
        { "label" => "i", "part_of_speech" => "pronoun" },
        { "label" => "want", "part_of_speech" => "verb" },
        { "label" => "more", "part_of_speech" => "important_function" },
        { "label" => "Food", "part_of_speech" => "noun", "links_to" => "food" },
      ]
      food = food_page(tiles: [
        { "label" => "apple", "part_of_speech" => "noun" },
        { "label" => "banana", "part_of_speech" => "noun" },
        { "label" => "hungry", "part_of_speech" => "adjective" },
        { "label" => "Play", "part_of_speech" => "noun", "links_to" => "play" },
      ])
      play = {
        "key" => "play", "name" => "Play",
        "tiles" => [
          { "label" => "ball", "part_of_speech" => "noun" },
          { "label" => "run", "part_of_speech" => "verb" },
          { "label" => "swing", "part_of_speech" => "noun" },
          { "label" => "Food", "part_of_speech" => "noun", "links_to" => "food" },
        ],
      }

      set_build = build_record(tiles: root_tiles, children: [food, play])
      described_class.new(admin_board_build: set_build).call

      ids = set_build.reload.art_report["boards"]
      food_board = Board.find(ids["food"])
      play_board = Board.find(ids["play"])

      expect(food_board.board_images.find { |bi| bi.label == "play" }.predictive_board_id).to eq(play_board.id)
      expect(play_board.board_images.find { |bi| bi.label == "food" }.predictive_board_id).to eq(food_board.id)
    end

    # The same word on two pages is one Image and one generation.
    it "resolves a label shared between pages once" do
      shared = food_page(tiles: [
        { "label" => "apple", "part_of_speech" => "noun" },
        { "label" => "banana", "part_of_speech" => "noun" },
        { "label" => "hungry", "part_of_speech" => "adjective" },
        { "label" => "more", "part_of_speech" => "important_function" },
      ])
      set_build = build_record(tiles: root_with_folder, children: [shared])

      expect { described_class.new(admin_board_build: set_build).call }.to change(Image, :count).by(7)

      queued = GenerateImagesJob.jobs.flat_map { |job| job["args"].first }
      expect(queued.size).to eq(7)
      expect(queued.uniq.size).to eq(7)
    end

    it "aborts the whole set when a page links to a key that doesn't exist" do
      broken = [
        { "label" => "i", "part_of_speech" => "pronoun" },
        { "label" => "want", "part_of_speech" => "verb" },
        { "label" => "more", "part_of_speech" => "important_function" },
        { "label" => "Food", "part_of_speech" => "noun", "links_to" => "nope" },
      ]
      set_build = build_record(tiles: broken, children: [food_page])

      expect { described_class.new(admin_board_build: set_build).call }
        .to raise_error(described_class::BuildError, /unknown page/)

      expect(Board.count).to eq(0)
      expect(set_build.reload.status).to eq("failed")
    end

    it "leaves a single-board build with no builder_root or builder_child marks" do
      root = described_class.new(admin_board_build: build_record(tiles: four_tiles)).call

      expect(root.settings).not_to have_key("builder_root")
      expect(root.settings).not_to have_key("builder_child")
      expect(root.predefined).to be(true)
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
