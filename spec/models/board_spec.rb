# == Schema Information
#
# Table name: boards
#
#  id                         :bigint           not null, primary key
#  user_id                    :bigint
#  name                       :string
#  parent_type                :string           not null
#  parent_id                  :bigint           not null
#  description                :text
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  cost                       :integer          default(0)
#  predefined                 :boolean          default(FALSE)
#  token_limit                :integer          default(0)
#  voice                      :string
#  status                     :string           default("pending")
#  number_of_columns          :integer          default(6)
#  small_screen_columns       :integer          default(3)
#  medium_screen_columns      :integer          default(8)
#  large_screen_columns       :integer          default(12)
#  display_image_url          :string
#  layout                     :jsonb
#  position                   :integer
#  audio_url                  :string
#  bg_color                   :string
#  margin_settings            :jsonb
#  settings                   :jsonb
#  category                   :string
#  data                       :jsonb
#  group_layout               :jsonb
#  image_parent_id            :integer
#  board_type                 :string
#  obf_id                     :string
#  language                   :string           default("en")
#  board_images_count         :integer          default(0), not null
#  published                  :boolean          default(FALSE)
#  favorite                   :boolean          default(FALSE)
#  vendor_id                  :bigint
#  slug                       :string           default("")
#  in_use                     :boolean          default(FALSE), not null
#  is_template                :boolean          default(FALSE), not null
#  board_screenshot_import_id :bigint
#  sub_board                  :boolean          default(TRUE), not null
#  generated_token            :string
#  generated_token_expires_at :datetime
#  metadata                   :jsonb
#  tags                       :string           default([]), not null, is an Array
#
require "rails_helper"

RSpec.describe Board, type: :model do

  describe "#set_current_word_list" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }

    it "persists the computed list so it is not recomputed on every read" do
      FactoryBot.create(:board_image, board: board)
      board.reload

      expect(board.data["current_word_list"]).to be_nil

      board.set_current_word_list
      board.save!

      # This used to fail: the method bound a LOCAL `data` shadowing the
      # attribute and mutated the jsonb hash in place, so ActiveRecord never
      # saw the record as dirty and the list was never written. Every board
      # missing it therefore re-queried board_images forever.
      expect(board.reload.data["current_word_list"]).to be_present
    end

    it "marks the record dirty so a caller's save writes the column" do
      FactoryBot.create(:board_image, board: board)
      board.reload

      board.set_current_word_list

      expect(board.changed).to include("data")
    end

    it "leaves the list unset for a board with no tiles" do
      board.set_current_word_list

      expect(board.data["current_word_list"]).to be_nil
    end
  end

  describe "#current_word_list" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }

    it "does not write on the read path" do
      FactoryBot.create(:board_image, board: board)
      board.reload

      expect(board.current_word_list).to be_present
      # `word_sample` calls this for every board in a card list; a GET must not
      # issue an UPDATE per board.
      expect(board.reload.data["current_word_list"]).to be_nil
    end
  end
  describe "#clone_with_images" do
    let(:user)  { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user, name: "Original Board") }
    let(:image) { FactoryBot.create(:image, user: user) }
    before { FactoryBot.create(:board_image, board: board, image: image) }

    it "creates a new board with the same name by default" do
      cloned = board.clone_with_images(user.id)
      expect(cloned).to be_a(Board)
      expect(cloned.id).not_to eq(board.id)
      expect(cloned.name).to eq("Original Board")
    end

    it "accepts a custom name" do
      cloned = board.clone_with_images(user.id, "Cloned Board")
      expect(cloned.name).to eq("Cloned Board")
    end

    it "assigns the cloned board to the target user" do
      other_user = FactoryBot.create(:user)
      cloned = board.clone_with_images(other_user.id)
      expect(cloned.user_id).to eq(other_user.id)
    end

    it "does not mark the clone as predefined" do
      board.update!(predefined: true)
      cloned = board.clone_with_images(user.id)
      expect(cloned.predefined).to be false
    end

    it "does not mark the clone as published" do
      board.update!(published: true)
      cloned = board.clone_with_images(user.id)
      expect(cloned.published).to be false
    end

    it "copies board images to the new board" do
      cloned = board.clone_with_images(user.id)
      expect(cloned.board_images.count).to eq(board.board_images.count)
    end

    it "does not inherit the source's display_image_url snapshot" do
      board.update_column(
        :display_image_url,
        "https://cdn.example.com/board_previews/#{board.id}/preview.png?v=123",
      )
      cloned = board.clone_with_images(user.id)
      expect(cloned.read_attribute(:display_image_url)).to be_nil
    end

    it "defaults the clone to its own auto preview" do
      cloned = board.clone_with_images(user.id)
      expect(cloned.settings["display_image_source"]).to eq("preview")
      expect(cloned.display_image_source).to eq("preview")
    end

    describe "cover render" do
      # Asserting on settings["preview_status"] rather than on
      # GenerateBoardPreviewJob.jobs: run_generate_preview_job defers the
      # Sidekiq push to ActiveRecord.after_all_transactions_commit, and under
      # transactional fixtures that commit never arrives — so the queue is
      # empty here whether or not the enqueue happened. mark_preview_queued!
      # runs synchronously, and it's what clients actually poll.
      it "queues a render for the clone" do
        cloned = board.clone_with_images(user.id)
        expect(cloned.reload.settings["preview_status"]).to eq("queued")
      end

      it "does not queue a render when the source has no tiles" do
        empty = FactoryBot.create(:board, user: user, name: "Empty")
        cloned = empty.clone_with_images(user.id)
        expect(cloned.reload.settings["preview_status"]).to be_nil
      end

      it "hands back a clone whose tile count is not the stale counter cache" do
        # The tile loop writes board_images with `board_id=`, so this instance's
        # board_images_count stays 0 without a reload — and `size`/`any?` read
        # that column, not the DB. This is the read that made the enqueue guard
        # always false.
        cloned = board.clone_with_images(user.id)
        expect(cloned.board_images.size).to eq(board.board_images.count)
        expect(cloned.board_images).to be_any
      end

      it "does not inherit the source's cover snapshot or render outcome" do
        board.update!(
          settings: board.settings.to_h.merge(
            "preset_display_image_url" => "https://cdn.example.com/source-cover.png",
            "preview_status" => "ok",
            "preview_generated_at" => 1.day.ago.iso8601,
          ),
        )

        cloned = board.clone_with_images(user.id).reload

        # The column is nulled on clone, so preset_display_image_url would fall
        # through to the inherited snapshot and resolve to the SOURCE's cover.
        expect(cloned.settings["preset_display_image_url"]).to be_nil
        expect(cloned.preset_display_image_url).to be_nil
        expect(cloned.settings["preview_generated_at"]).to be_nil
        expect(cloned.settings["preview_status"]).to eq("queued")
      end
    end

    context "tile display_image_url fallback on clone" do
      let(:other_user) { FactoryBot.create(:user) }

      it "backfills from the original image when the resolved image has no src_url" do
        # Source image has no user_id so the clone creates a fresh stub
        # (no docs, no src_url). The backfill uses the original image's URL.
        image.update_columns(src_url: "https://cdn.example.com/original.webp", user_id: nil)

        cloned = board.clone_with_images(other_user.id)
        cloned_tile = cloned.reload.board_images.first

        expect(cloned_tile.display_image_url).to eq("https://cdn.example.com/original.webp")
      end

      it "picks up the source image's src_url via set_defaults" do
        image.update_column(:src_url, "https://cdn.example.com/source.webp")

        cloned = board.clone_with_images(other_user.id)
        cloned_tile = cloned.reload.board_images.first

        # Cross-user clone reuses the original image; set_defaults copies its src_url
        expect(cloned_tile.display_image_url).to eq("https://cdn.example.com/source.webp")
      end
    end

    # A clone used to copy the source tile's display_label verbatim, one line
    # after set_labels had folded it — so a Title Cased seed board propagated
    # "Higher" into every board built from it.
    context "tile casing on clone" do
      def clone_tile_reading(text, source_attrs = {})
        source_image = FactoryBot.create(:image, user: user)
        source_image.update_columns(label: text.downcase, display_label: text)
        tile = FactoryBot.create(:board_image, board: board, image: source_image)
        tile.update_columns({ label: text.downcase, display_label: text }.merge(source_attrs))

        # Match on the lowercase key, not image_id: the clone re-resolves each
        # tile to the best image for the label and may land on a different row.
        # reload so a second call in one example sees the tile it just added.
        cloned = board.reload.clone_with_images(user.id)
        cloned.reload.board_images.find_by(label: text.downcase)
      end

      it "folds a stuck leading capital on a word tile" do
        expect(clone_tile_reading("Higher").display_label).to eq("higher")
      end

      it "keeps the capital on a door tile" do
        tile = clone_tile_reading("Food", data: { "mute_name" => true })
        expect(tile.display_label).to eq("Food")
      end

      it "keeps deliberate casing" do
        expect(clone_tile_reading("iPad").display_label).to eq("iPad")
      end

      # A key legend is not vocabulary: folding these would spell in lowercase
      # and rename the Space key to "space".
      it "keeps a keyboard key's legend" do
        space = clone_tile_reading("Space", data: { "tile_type" => "action", "tile_action" => "space" })
        letter = clone_tile_reading("A", data: { "tile_type" => "letter" })

        expect(space.display_label).to eq("Space")
        expect(letter.display_label).to eq("A")
      end
    end
  end

  describe "#check_in_use (before_save)" do
    let(:user)  { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user, name: "Home") }

    it "is not in_use with no ChildBoard" do
      board.save!
      expect(board.reload.in_use).to be(false)
    end

    it "is in_use when directly attached to a communicator (Board Builder path)" do
      communicator = FactoryBot.create(:child_account, user: user)
      communicator.child_boards.create!(board: board, created_by_id: user.id)

      board.save!
      expect(board.reload.in_use).to be(true)
    end

    it "is in_use when it is the source of a clone on a communicator (assign path)" do
      communicator = FactoryBot.create(:child_account, user: user)
      clone = FactoryBot.create(:board, user: user, name: "Home copy", is_template: true)
      communicator.child_boards.create!(board: clone, original_board: board, created_by_id: user.id)

      board.save!
      expect(board.reload.in_use).to be(true)
    end

    it "does not mark a brand-new board in_use because unrelated direct-attach rows exist (nil-id guard)" do
      communicator = FactoryBot.create(:child_account, user: user)
      communicator.child_boards.create!(board: board, created_by_id: user.id)

      # With a nil id at first save, the unguarded query matched the row above
      # via `original_board_id: nil` and flagged every new board in_use.
      fresh = FactoryBot.create(:board, user: user, name: "Fresh")
      expect(fresh.reload.in_use).to be(false)
    end
  end

  describe "communicator assignment in api views" do
    let(:user)         { FactoryBot.create(:user) }
    let(:communicator) { FactoryBot.create(:child_account, user: user, name: "Mason") }
    let(:board)        { FactoryBot.create(:board, user: user, name: "Core 60") }

    context "when attached directly (Board Builder path — no original_board_id)" do
      before { communicator.child_boards.create!(board: board, created_by_id: user.id) }

      it "lists the communicator in the show payload" do
        view = board.reload.api_view_with_predictive_images(user)

        expect(view[:communicator_accounts]).to eq([{ id: communicator.id, name: "Mason" }])
        expect(view[:communicator_account_data].map { |d| d[:acct_id] }).to eq([communicator.id])
        expect(view[:child_boards].map { |cb| cb[:child_account_id] }).to eq([communicator.id])
        expect(view[:in_use]).to be(true)
      end

      it "names the communicator in in_use_by" do
        expect(board.reload.in_use_by).to eq("Mason")
      end
    end

    context "when it is the source of an assigned clone (original_board_id path)" do
      before do
        clone = FactoryBot.create(:board, user: user, name: "Core 60 copy", is_template: true)
        communicator.child_boards.create!(board: clone, original_board: board, created_by_id: user.id)
      end

      it "lists the communicator in the show payload" do
        view = board.reload.api_view_with_predictive_images(user)

        expect(view[:communicator_accounts]).to eq([{ id: communicator.id, name: "Mason" }])
        expect(view[:in_use]).to be(true)
      end
    end

    it "returns empty communicator lists for an unassigned board" do
      view = board.reload.api_view_with_predictive_images(user)

      expect(view[:communicator_accounts]).to eq([])
      expect(view[:communicator_account_data]).to eq([])
      expect(view[:child_boards]).to eq([])
    end

    context "when a ChildBoard is orphaned (its child_account was deleted)" do
      # original_child_boards is dependent: :nullify, and older DBs lack an
      # enforced child_account_id FK, so account teardown can leave a ChildBoard
      # pointing at a gone child_account. api_view reads cb.child_account.id
      # directly — an orphan used to 500 /api/boards. The test DB enforces the
      # FK, so the dangling row can't be inserted; simulate it in memory.
      let(:orphan) { ChildBoard.new(board: board, original_board: board, status: "active") }

      before do
        board.update_column(:in_use, true)
        allow(orphan).to receive(:child_account).and_return(nil)
        allow(orphan).to receive(:child_account_id).and_return(999_999)
        stub_rel = ->(rows) { double(includes: rows) }
        allow(board).to receive(:original_child_boards).and_return(stub_rel.call([orphan]))
        allow(board).to receive(:child_boards).and_return(stub_rel.call([]))
      end

      it "filters the orphan out of communicator_child_boards" do
        expect(board.communicator_child_boards).to eq([])
      end

      it "does not raise in the index api_view and skips the orphan" do
        view = nil
        expect { view = board.api_view(user) }.not_to raise_error
        expect(view[:communicator_account_data]).to eq([])
      end

      it "does not raise in the show api_view and skips the orphan" do
        view = nil
        expect { view = board.api_view_with_predictive_images(user) }.not_to raise_error
        expect(view[:communicator_account_data]).to eq([])
        expect(view[:communicator_accounts]).to eq([])
        expect(view[:child_boards]).to eq([])
      end
    end
  end

  describe "#check_is_sub_board (before_save)" do
    let(:user) { FactoryBot.create(:user) }

    it "marks a board with a parent (predictive link) as a sub_board" do
      child  = FactoryBot.create(:board, user: user, name: "Food")
      parent = FactoryBot.create(:board, user: user, name: "Home")
      FactoryBot.create(:board_image, board: parent, predictive_board_id: child.id)

      child.save!
      expect(child.reload.sub_board).to be(true)
    end

    it "keeps a builder_root a main board even when a child page links back to it" do
      # The controller assign_parents the root before saving (so it isn't a Menu);
      # mirror that so the main_boards scope (non_menus) can include it.
      root = FactoryBot.build(:board, user: user, name: "Communication Board",
                                      settings: { "builder_root" => true })
      root.assign_parent
      root.save!
      child = FactoryBot.create(:board, user: user, name: "Food")
      # The child's authored "Home" tile points back at the root, like the seed.
      FactoryBot.create(:board_image, board: child, predictive_board_id: root.id)

      root.save!
      expect(root.reload.sub_board).to be(false)
      expect(Board.main_boards.where(id: root.id)).to exist
    end
  end

  describe "#update_grid_layout" do
    let(:user)  { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user, layout: { "lg" => [] }) }

    it "does nothing when given a non-array layout" do
      expect { board.update_grid_layout("invalid", "lg") }.not_to raise_error
    end

    it "does nothing when given an empty array" do
      expect { board.update_grid_layout([], "lg") }.not_to raise_error
    end

    it "updates layout for the given screen size when board_image exists" do
      image      = FactoryBot.create(:image, user: user)
      bi         = FactoryBot.create(:board_image, board: board, image: image)
      layout_item = { "i" => bi.id.to_s, "x" => 0, "y" => 0, "w" => 1, "h" => 1 }

      board.update_grid_layout([layout_item], "lg")
      board.reload

      expect(board.layout["lg"]).to be_present
      expect(board.layout["lg"].first["i"]).to eq(bi.id.to_s)
    end
  end

  describe "#apply_layout! derived screen sync" do
    let(:user)  { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }

    before { board.update_columns(large_screen_columns: 12, medium_screen_columns: 8, small_screen_columns: 4) }

    def tile(label, position)
      FactoryBot.create(:board_image, board: board, position: position,
                                      image: FactoryBot.create(:image, label: label, user: user))
    end

    def lg_layout(tiles)
      tiles.each_with_index.map { |bi, i| { "i" => bi.id.to_s, "x" => i % 12, "y" => i / 12, "w" => 1, "h" => 1 } }
    end

    it "reflows md/sm from an edited lg layout so nothing overflows the narrower grids" do
      tiles = Array.new(14) { |i| tile("w#{i}", i) }

      board.apply_layout!(layout: lg_layout(tiles), screen_size: "lg")

      tiles.each do |bi|
        bi.reload
        expect(bi.layout["md"]["x"] + bi.layout["md"]["w"]).to be <= 8
        expect(bi.layout["sm"]["x"] + bi.layout["sm"]["w"]).to be <= 4
      end
    end

    it "marks a hand-edited sm screen as customized and leaves it alone on a later lg edit" do
      tiles = Array.new(3) { |i| tile("w#{i}", i) }

      # User hand-arranges sm: reverse order in a single column.
      sm_layout = tiles.reverse.each_with_index.map { |bi, i| { "i" => bi.id.to_s, "x" => 0, "y" => i, "w" => 1, "h" => 1 } }
      board.apply_layout!(layout: sm_layout, screen_size: "sm")
      expect(board.reload.settings["custom_screen_layouts"]).to include("sm")

      custom_sm = tiles.map { |bi| bi.reload.layout["sm"] }

      # Now edit lg — sm must be preserved (customized), md must be regenerated.
      board.apply_layout!(layout: lg_layout(tiles), screen_size: "lg")

      expect(tiles.map { |bi| bi.reload.layout["sm"] }).to eq(custom_sm)
    end
  end

  describe "#run_generate_preview_job" do
    let(:user)  { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }

    around { |example| Sidekiq::Testing.fake! { example.run } }
    before { GenerateBoardPreviewJob.jobs.clear }

    it "pushes immediately when no transaction is open" do
      board.run_generate_preview_job

      expect(GenerateBoardPreviewJob.jobs.size).to eq(1)
      expect(GenerateBoardPreviewJob.jobs.last["args"].first).to eq(board.id)
    end

    # The render runs in a Sidekiq worker on its own connection, so it cannot
    # see rows a still-open transaction hasn't committed. Pushing mid-transaction
    # is what made an admin Board Builder run log RecordNotFound per page.
    it "holds the push until the enclosing transaction commits" do
      Board.transaction do
        board.run_generate_preview_job
        expect(GenerateBoardPreviewJob.jobs).to be_empty
      end

      expect(GenerateBoardPreviewJob.jobs.size).to eq(1)
      expect(GenerateBoardPreviewJob.jobs.last["args"].first).to eq(board.id)
    end

    it "never pushes when the enclosing transaction rolls back" do
      Board.transaction do
        board.run_generate_preview_job
        raise ActiveRecord::Rollback
      end

      expect(GenerateBoardPreviewJob.jobs).to be_empty
    end

    # The status flag is a write on the board's own row, so it belongs inside
    # the transaction: it lands or rolls back with the board it describes.
    it "still marks the board queued inside the transaction" do
      Board.transaction do
        board.run_generate_preview_job
        expect(board.reload.settings["preview_status"]).to eq("queued")
      end
    end
  end

  describe ".find_or_create_images_from_word_list" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }

    context "when all words are new" do
      it "creates new images for each word" do
        words = ["apple", "banana", "cherry"]
        expect {
          board.find_or_create_images_from_word_list(words)
        }.to change(Image, :count).by(3)
        expect(board.images.pluck(:label)).to match_array(words)
      end
    end

    context "with a max_generate budget" do
      let(:words) { ["apple", "banana", "cherry", "durian", "elderberry"] }

      before { GenerateImagesJob.clear }

      it "queues at most max_generate images and returns the queued count" do
        queued = board.find_or_create_images_from_word_list(words, max_generate: 2)

        expect(queued).to eq(2)
        queued_ids = GenerateImagesJob.jobs.flat_map { |j| j["args"][0] }
        expect(queued_ids.size).to eq(2)
      end

      it "still adds every word as a tile, marking over-budget tiles skipped" do
        board.find_or_create_images_from_word_list(words, max_generate: 2)

        expect(board.images.pluck(:label)).to match_array(words)
        expect(board.board_images.where(status: "skipped").count).to eq(3)
      end

      it "does not count words with existing art against the budget" do
        admin_user = User.find_by(id: User::DEFAULT_ADMIN_ID) || FactoryBot.create(:admin_user, id: User::DEFAULT_ADMIN_ID)
        apple = FactoryBot.create(:image, label: "apple", user: admin_user)
        FactoryBot.create(:doc, documentable: apple, user: admin_user, processed: "img")

        queued = board.find_or_create_images_from_word_list(words, max_generate: 4)

        expect(queued).to eq(4)
        expect(board.board_images.where(status: "skipped").count).to eq(0)
      end

      it "queues everything when max_generate is nil" do
        queued = board.find_or_create_images_from_word_list(words)

        expect(queued).to eq(5)
        expect(board.board_images.where(status: "skipped").count).to eq(0)
      end

      it "queues nothing when max_generate is zero" do
        queued = board.find_or_create_images_from_word_list(words, max_generate: 0)

        expect(queued).to eq(0)
        expect(GenerateImagesJob.jobs).to be_empty
        expect(board.board_images.where(status: "skipped").count).to eq(5)
      end
    end

    context "with menu_prompts (menu board items)" do
      let(:words) { ["single", "virginia"] }
      let(:prompts) do
        {
          "single" => "A single classic burger with fry sauce. Menu photo.",
          "virginia" => "A burger topped with pimento cheese and ham. Menu photo.",
        }
      end
      let(:admin_user) { User.find_by(id: User::DEFAULT_ADMIN_ID) || FactoryBot.create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

      before { GenerateImagesJob.clear }

      it "creates a fresh private menu image with the description prompt even when the label exists in the library" do
        existing = FactoryBot.create(:image, label: "single", user: admin_user)
        FactoryBot.create(:doc, documentable: existing, user: admin_user, processed: "img")

        queued = board.find_or_create_images_from_word_list(words, menu_prompts: prompts)

        expect(queued).to eq(2)
        fresh = board.images.find_by(label: "single")
        expect(fresh.id).not_to eq(existing.id)
        expect(fresh.is_private).to be(true)
        expect(fresh.image_type).to eq("menu")
        expect(fresh.user_id).to eq(user.id)
        expect(fresh.image_prompt).to eq(prompts["single"])
      end

      it "matches prompts case-insensitively" do
        queued = board.find_or_create_images_from_word_list(["Single"], menu_prompts: prompts)

        expect(queued).to eq(1)
        expect(board.images.by_label("Single").first.image_type).to eq("menu")
      end

      it "falls back to library reuse for menu items over the budget" do
        existing = FactoryBot.create(:image, label: "virginia", user: admin_user)
        FactoryBot.create(:doc, documentable: existing, user: admin_user, processed: "img")

        queued = board.find_or_create_images_from_word_list(words, max_generate: 1, menu_prompts: prompts)

        expect(queued).to eq(1)
        expect(board.images.find_by(label: "single").image_type).to eq("menu")
        expect(board.images.find_by(label: "virginia").id).to eq(existing.id)
        expect(board.board_images.where(status: "skipped").count).to eq(0)
      end

      it "marks over-budget menu items with no library art as skipped" do
        queued = board.find_or_create_images_from_word_list(words, max_generate: 1, menu_prompts: prompts)

        expect(queued).to eq(1)
        expect(board.board_images.where(status: "skipped").count).to eq(1)
      end

      it "reuses library art without generating when max_generate is zero" do
        existing = FactoryBot.create(:image, label: "single", user: admin_user)
        FactoryBot.create(:doc, documentable: existing, user: admin_user, processed: "img")

        queued = board.find_or_create_images_from_word_list(words, max_generate: 0, menu_prompts: prompts)

        expect(queued).to eq(0)
        expect(board.images.find_by(label: "single").id).to eq(existing.id)
        expect(GenerateImagesJob.jobs).to be_empty
      end
    end

    context "when some words already exist" do
      context "by the admin user" do
        let(:admin_user) { FactoryBot.create(:user, role: "admin", id: User::DEFAULT_ADMIN_ID) }
        before do
          FactoryBot.create(:image, label: "apple", user: admin_user)
        end

        it "creates images only for the new words" do
          words = ["apple", "banana", "cherry"]
          expect {
            board.find_or_create_images_from_word_list(words)
          }.to change(Image, :count).by(2)
          expect(board.images.pluck(:label)).to match_array(words)
        end
      end

      context "by another regular user" do
        let(:other_user) { FactoryBot.create(:user) }
        before do
          FactoryBot.create(:image, label: "apple", user: other_user)
        end

        it "creates images for all words since existing image is by a different user" do
          words = ["apple", "banana", "cherry"]
          expect {
            board.find_or_create_images_from_word_list(words)
          }.to change(Image, :count).by(3)
          expect(board.images.pluck(:label)).to match_array(words)
        end
      end
    end

    context "when all words already exist" do
      before do
        FactoryBot.create(:image, label: "apple")
        FactoryBot.create(:image, label: "banana")
        FactoryBot.create(:image, label: "cherry")
      end

      it "does not create any new images" do
        words = ["apple", "banana", "cherry"]
        expect {
          board.find_or_create_images_from_word_list(words)
        }.not_to change(Image, :count)
        expect(board.images.pluck(:label)).to match_array(words)
      end
    end

    context "when words have different casing" do
      before do
        FactoryBot.create(:image, label: "Apple")
      end

      # `label` is a lowercase matching key, so "Apple" and "apple" are the same
      # image. Reusing it is the whole point: a case-sensitive lookup used to
      # miss the curated row and mint a blank, art-less twin beside it.
      it "reuses the existing image instead of creating a differently-cased twin" do
        words = ["apple", "banana", "cherry"]
        expect {
          board.find_or_create_images_from_word_list(words)
        }.to change(Image, :count).by(2)
      end

      # A bare leading capital carries no intent — it's just how a word-list
      # line gets typed — so it is folded to the lowercase AAC default rather
      # than becoming this image's permanent display text. Deliberate casing
      # ("iPad", "TV") is what survives; see Labels::CaseNormalizer.
      it "folds an accidental leading capital out of the display text" do
        board.find_or_create_images_from_word_list(["apple"])

        apple = Image.by_label("apple").first
        expect(apple.label).to eq("apple")
        expect(apple.display_label).to eq("apple")
      end
    end

    context "when words contain leading/trailing whitespace" do
      # Whitespace is stripped as part of building the matching key, so
      # "  apple  " and "apple" no longer land on two separate images.
      it "strips the labels down to the matching key" do
        words = ["  apple  ", "banana", "  cherry"]
        expect {
          board.find_or_create_images_from_word_list(words)
        }.to change(Image, :count).by(3)
        expect(board.images.pluck(:label)).to include("apple", "cherry", "banana")
      end
    end
  end

  describe "#viewable_by?" do
    let(:owner)     { FactoryBot.create(:user) }
    let(:stranger)  { FactoryBot.create(:user) }
    let(:admin)     { FactoryBot.create(:admin_user) }

    context "when the board is published" do
      let(:board) { FactoryBot.create(:board, user: owner, published: true) }

      it "is viewable by anyone, including logged-out visitors" do
        expect(board.viewable_by?(nil)).to be(true)
        expect(board.viewable_by?(stranger)).to be(true)
        expect(board.viewable_by?(owner)).to be(true)
      end
    end

    context "when the board is private (unpublished)" do
      let(:board) { FactoryBot.create(:board, user: owner, published: false) }

      it "is not viewable by a logged-out visitor" do
        expect(board.viewable_by?(nil)).to be(false)
      end

      it "is not viewable by an unrelated user" do
        expect(board.viewable_by?(stranger)).to be(false)
      end

      it "is viewable by the owner" do
        expect(board.viewable_by?(owner)).to be(true)
      end

      it "is viewable by an admin" do
        expect(board.viewable_by?(admin)).to be(true)
      end

      it "is viewable by a team member the board is shared with" do
        team = FactoryBot.create(:team, created_by: owner)
        TeamBoard.create!(team: team, board: board)
        TeamUser.create!(team: team, user: stranger, role: "member")
        expect(board.reload.viewable_by?(stranger)).to be(true)
      end
    end
  end

  describe "AI word-generation language threading" do
    let(:openai) { instance_double(OpenAiClient) }

    before { allow(OpenAiClient).to receive(:new).and_return(openai) }

    describe "#get_word_suggestions" do
      let(:board) { FactoryBot.create(:board, language: "es", board_type: "static") }

      it "defaults the language to the board's own language" do
        expect(openai).to receive(:get_word_suggestions)
          .with("drink", 5, [], anything, hash_including(language: "es"))
          .and_return({ content: '{"words":[]}' })
        board.get_word_suggestions("drink", 5, [])
      end

      it "lets an explicit language override the board's language" do
        expect(openai).to receive(:get_word_suggestions)
          .with("drink", 5, [], anything, hash_including(language: "fr"))
          .and_return({ content: '{"words":[]}' })
        board.get_word_suggestions("drink", 5, [], language: "fr")
      end
    end

    describe "#get_word_suggestions_from_prompt" do
      let(:board) { FactoryBot.create(:board, language: "de", board_type: "static") }

      it "defaults the language to the board's own language" do
        expect(openai).to receive(:get_word_suggestions_from_prompt)
          .with("a prompt", hash_including(language: "de"))
          .and_return({ content: '{"words":[]}' })
        board.get_word_suggestions_from_prompt("a prompt")
      end

      it "lets an explicit language override the board's language" do
        expect(openai).to receive(:get_word_suggestions_from_prompt)
          .with("a prompt", hash_including(language: "it"))
          .and_return({ content: '{"words":[]}' })
        board.get_word_suggestions_from_prompt("a prompt", language: "it")
      end
    end
  end

  describe "language change retranslation" do
    let(:board) { FactoryBot.create(:board, language: "en") }

    it "schedules translations when language changes" do
      expect(board).to receive(:schedule_translations_for).with("es")
      board.update!(language: "es")
    end

    it "does not schedule when language is unchanged" do
      expect(board).not_to receive(:schedule_translations_for)
      board.update!(name: "renamed")
    end

    it "enqueues TranslateBoardImagesJob on language change" do
      allow(Rails.cache).to receive(:exist?).and_return(false)
      allow(Rails.cache).to receive(:write)
      expect(TranslateBoardImagesJob).to receive(:perform_async).with(board.id, "es")
      board.update!(language: "es")
    end

    it "is a no-op when switching to English" do
      board.update!(language: "es")
      expect(TranslateBoardImagesJob).not_to receive(:perform_async)
      board.update!(language: "en")
    end
  end

  describe "#api_view" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) do
      FactoryBot.create(:board, user: user, published: true, position: 3,
        data: { "current_word_list" => ["apple", "banana"] })
    end

    it "exposes published, position, and data from the board" do
      view = board.api_view(user)
      expect(view[:published]).to be(true)
      expect(view[:position]).to eq(3)
      expect(view[:data]).to eq("current_word_list" => ["apple", "banana"])
    end
  end

  describe "#add_image" do
    let(:user)  { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user, voice: "polly:kevin") }
    let(:image) { FactoryBot.create(:image, user: user) }

    # SaveAudioJob used to be enqueued twice per image: once explicitly here
    # and once by BoardImage's after_create callback. add_image now leaves
    # audio entirely to the callback.
    it "enqueues SaveAudioJob exactly once for the new board image" do
      expect { board.add_image(image.id) }
        .to change(SaveAudioJob.jobs, :size).by(1)
    end

    it "enqueues the audio job for the created board image and voice" do
      board_image = board.add_image(image.id)

      args = SaveAudioJob.jobs.last["args"]
      expect(args[1]).to eq("polly:kevin")
      expect(args[2]).to eq(board_image.id)
    end
  end

  describe "#display_image_url precedence" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }

    def attach_preview(bytes = "png-bytes")
      board.preview_image.attach(
        io: StringIO.new(bytes),
        filename: "preview.png",
        content_type: "image/png",
      )
    end

    context "with neither a custom cover nor a preview" do
      it "returns the stored column value (seed thumbnail)" do
        board.update_column(:display_image_url, "https://example.com/seed.png")
        expect(board.display_image_url).to eq("https://example.com/seed.png")
      end
    end

    context "with a preview attached" do
      before { attach_preview }

      # Active Storage signed URLs embed an `expires_at` derived from
      # `Time.current`, so two `.url` calls a millisecond apart produce
      # different strings. Freeze time so both calls share an expiry.
      it "the live preview wins over the seed column even without the follow flag" do
        board.update_column(:display_image_url, "https://example.com/seed.png")
        freeze_time do
          expect(board.display_image_url).to eq(board.preview_image_url)
        end
      end

      it "resolves to the new URL after the preview regenerates" do
        original_url = freeze_time { board.display_image_url }
        board.preview_image.purge
        attach_preview("new-png-bytes")

        freeze_time do
          expect(board.display_image_url).to eq(board.preview_image_url)
          expect(board.display_image_url).not_to eq(original_url) if board.preview_image_url != original_url
        end
      end
    end

    context "with an explicit custom cover (preset_display_image attached)" do
      before do
        attach_preview
        board.preset_display_image.attach(
          io: StringIO.new("cover-bytes"),
          filename: "preset_display_image.png",
          content_type: "image/png",
        )
      end

      it "the custom cover wins over the auto preview" do
        expect(board.display_image_url).to eq(board.display_preset_image_url)
        expect(board.display_image_url).not_to eq(board.preview_image_url)
      end
    end

    context "with a legacy tile pick (display_image_is_custom flag, backward compat)" do
      before do
        attach_preview
        board.update_column(:display_image_url, "https://example.com/picked-tile.png")
        board.update!(settings: board.settings.merge("display_image_is_custom" => true))
      end

      it "the picked column value wins over the auto preview" do
        freeze_time do
          expect(board.display_image_url).to eq("https://example.com/picked-tile.png")
          expect(board.display_image_url).not_to eq(board.preview_image_url)
        end
      end

      it "an uploaded custom cover still outranks the tile pick" do
        board.preset_display_image.attach(
          io: StringIO.new("cover-bytes"),
          filename: "preset_display_image.png",
          content_type: "image/png",
        )
        expect(board.display_image_url).to eq(board.display_preset_image_url)
      end

      it "falls back to the preview when the flag is set but the column is blank" do
        board.update_column(:display_image_url, nil)
        freeze_time do
          expect(board.display_image_url).to eq(board.preview_image_url)
        end
      end
    end

    context "with the explicit switch settings[display_image_source]" do
      before { attach_preview }

      it "source=custom serves the picked column value over the auto preview" do
        board.update_column(:display_image_url, "https://example.com/picked-tile.png")
        board.update!(settings: board.settings.merge("display_image_source" => "custom"))
        freeze_time do
          expect(board.display_image_url).to eq("https://example.com/picked-tile.png")
          expect(board.display_image_url).not_to eq(board.preview_image_url)
        end
      end

      # The switch-back path, and the reason the echo-back clobber is harmless:
      # in preview mode the column is ignored, so a stale URL stamped into it by
      # a generic save can never freeze the thumbnail.
      it "source=preview serves the live auto preview, ignoring a stale column value" do
        board.update_column(:display_image_url, "https://example.com/old-pick.png")
        board.update!(settings: board.settings.merge("display_image_source" => "preview"))
        freeze_time do
          expect(board.display_image_url).to eq(board.preview_image_url)
          expect(board.display_image_url).not_to eq("https://example.com/old-pick.png")
        end
      end
    end

    describe "#display_image_source" do
      it "defaults to preview" do
        expect(board.display_image_source).to eq("preview")
      end

      it "infers custom when a cover is uploaded (backward compat)" do
        board.preset_display_image.attach(io: StringIO.new("c"), filename: "c.png", content_type: "image/png")
        expect(board.display_image_source).to eq("custom")
      end

      it "infers custom from the legacy display_image_is_custom flag (backward compat)" do
        board.update!(settings: board.settings.merge("display_image_is_custom" => true))
        expect(board.display_image_source).to eq("custom")
      end

      it "an explicit stored source always wins over inference" do
        board.preset_display_image.attach(io: StringIO.new("c"), filename: "c.png", content_type: "image/png")
        board.update!(settings: board.settings.merge("display_image_source" => "preview"))
        expect(board.display_image_source).to eq("preview")
      end
    end
  end

  describe "#preset_display_image_url" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }

    it "tracks the live preview rather than a frozen settings snapshot" do
      board.update!(settings: board.settings.merge("preset_display_image_url" => "https://example.com/stale.png"))
      board.preview_image.attach(
        io: StringIO.new("png-bytes"),
        filename: "preview.png",
        content_type: "image/png",
      )

      freeze_time do
        expect(board.preset_display_image_url).to eq(board.preview_image_url)
        expect(board.preset_display_image_url).not_to eq("https://example.com/stale.png")
      end
    end

    it "falls back to the legacy settings snapshot only when nothing else resolves" do
      board.update_column(:display_image_url, nil)
      board.update!(settings: board.settings.merge("preset_display_image_url" => "https://example.com/legacy.png"))

      expect(board.preset_display_image_url).to eq("https://example.com/legacy.png")
    end
  end

  describe "#api_view_with_predictive_images parent_boards thumbnails" do
    let(:user) { FactoryBot.create(:user) }
    let(:child) { FactoryBot.create(:board, user: user) }
    let(:parent) { FactoryBot.create(:board, user: user) }

    before do
      # A "parent board" is one whose board_image points back at `child`
      # via predictive_board_id.
      FactoryBot.create(:board_image, board: parent, predictive_board_id: child.id)
    end

    it "exposes display_image_url and preview_image_url for each parent board" do
      entry = child.api_view_with_predictive_images(user)[:parent_boards].find { |pb| pb[:id] == parent.id }

      expect(entry).to include(:id, :name, :slug, :board_type, :display_image_url, :preview_image_url)
    end

    it "falls back to the stored display_image_url when no preview is attached" do
      parent.update_column(:display_image_url, "https://example.com/parent-cover.png")

      entry = child.api_view_with_predictive_images(user)[:parent_boards].find { |pb| pb[:id] == parent.id }

      expect(entry[:display_image_url]).to eq("https://example.com/parent-cover.png")
      expect(entry[:preview_image_url]).to be_nil
    end

    it "uses the live preview URL when a preview image is attached" do
      parent.preview_image.attach(
        io: StringIO.new("png-bytes"),
        filename: "preview.png",
        content_type: "image/png",
      )

      freeze_time do
        entry = child.api_view_with_predictive_images(user)[:parent_boards].find { |pb| pb[:id] == parent.id }

        expect(entry[:preview_image_url]).to eq(parent.preview_image_url)
        expect(entry[:display_image_url]).to eq(parent.preview_image_url)
      end
    end
  end

  describe "#api_view_with_predictive_images original_menu_image_url" do
    let(:user) { FactoryBot.create(:user) }
    let(:menu) { FactoryBot.create(:menu, user: user, name: "Joe's Diner") }
    let(:board) do
      FactoryBot.create(:board, user: user, board_type: "menu",
                                parent_type: "Menu", parent_id: menu.id)
    end

    it "exposes the original uploaded menu image URL for menu boards" do
      allow_any_instance_of(Menu).to receive(:menu_image_url)
        .and_return("https://cdn.example.com/menu.jpg")

      view = board.api_view_with_predictive_images(user)

      expect(view[:original_menu_image_url]).to eq("https://cdn.example.com/menu.jpg")
    end

    it "is nil when the menu has no image attached" do
      expect(board.api_view_with_predictive_images(user)[:original_menu_image_url]).to be_nil
    end

    it "is nil for non-menu boards" do
      plain = FactoryBot.create(:board, user: user)

      expect(plain.api_view_with_predictive_images(user)[:original_menu_image_url]).to be_nil
    end
  end

  describe ".from_obf" do
    let(:user) { create(:user) }

    let(:obf_hash) do
      {
        "format" => "open-board-0.1",
        "id" => "simple",
        "locale" => "en",
        "name" => "Simple Board",
        "grid" => { "rows" => 2, "columns" => 2, "order" => [[1, 2], [nil, nil]] },
        "buttons" => [
          { "id" => 1, "label" => "happy" },
          { "id" => 2, "label" => "sad" },
        ],
        "images" => [],
        "sounds" => [],
      }
    end

    it "creates a board with the right name, columns, and obf_id" do
      board, _data = described_class.from_obf(obf_hash, user)
      expect(board).to be_persisted
      expect(board.name).to eq("Simple Board")
      expect(board.obf_id).to eq("simple")
      expect(board.large_screen_columns).to eq(2)
    end

    it "imports each button as a BoardImage and stamps grid coordinates" do
      board, dynamic_data = described_class.from_obf(obf_hash, user)
      expect(board.board_images.count).to eq(2)
      expect(dynamic_data.values.map { |v| v["label"] }).to contain_exactly("happy", "sad")
      happy_bi = board.board_images.joins(:image).where(images: { label: "happy" }).first
      expect(happy_bi.layout["lg"]).to include("x" => 0, "y" => 0)
    end

    # Regression: dynamic_data is keyed per TILE, not per Image. Core 60/84
    # author both a "more" word button and a "More" folder button, which resolve
    # to one case-insensitively-matched Image. Keying on the Image let whichever
    # button came second overwrite the first's row — so on a page authoring the
    # FOLDER first (food.obf) the word's `load_board`-less row won, and
    # ObzImporter#link_dynamic_boards! left the folder tile dead.
    it "returns one dynamic_data row per tile when two buttons share an Image" do
      shared_image_obf = {
        "format" => "open-board-0.1",
        "id" => "shared",
        "name" => "Shared",
        "grid" => { "rows" => 1, "columns" => 2, "order" => [[1, 2]] },
        "buttons" => [
          { "id" => 1, "label" => "More", "load_board" => { "path" => "boards/more.obf" } },
          { "id" => 2, "label" => "more" },
        ],
        "images" => [],
        "sounds" => [],
      }

      board, dynamic_data = described_class.from_obf(shared_image_obf, user)

      expect(board.board_images.count).to eq(2)
      expect(dynamic_data.size).to eq(2)
      expect(dynamic_data.keys).to match_array(board.board_images.map(&:id))
      folder_row = dynamic_data.values.find { |row| row["dynamic_board"].present? }
      expect(folder_row).to be_present
      expect(folder_row["label"]).to eq("More")
      expect(BoardImage.find(folder_row["board_image_id"]).display_label).to eq("More")
    end

    it "re-raises instead of silently returning nil on malformed input" do
      expect {
        described_class.from_obf("not json", user)
      }.to raise_error(JSON::ParserError)
    end

    it "accepts a Hash, a JSON string, or a Pathname" do
      json = obf_hash.to_json
      expect(described_class.from_obf(json, user).first).to be_persisted
    end

    # Regression: imported tiles used to set skip_create_voice_audio=true,
    # which silenced BoardImage's after_create audio hook. Result: tapping
    # an imported tile produced no sound. Audio should enqueue exactly the
    # same way as boards created any other way.
    it "enqueues SaveAudioJob for each imported BoardImage so tile audio works" do
      Sidekiq::Testing.fake! do
        SaveAudioJob.clear
        described_class.from_obf(obf_hash, user)
        expect(SaveAudioJob.jobs.size).to eq(2)
        voices = SaveAudioJob.jobs.map { |j| j["args"][1] }
        expect(voices).to all(be_present)
      end
    end
  end

  describe ".from_obf — image policy (private + opt-in for binaries)" do
    let(:user) { create(:user) }

    let(:obf_with_image_url) do
      {
        "format" => "open-board-0.1",
        "id" => "imgtest",
        "name" => "ImgTest",
        "grid" => { "rows" => 1, "columns" => 1, "order" => [["b1"]] },
        "buttons" => [{ "id" => "b1", "label" => "hi", "image_id" => "i1" }],
        "images" => [{
          "id" => "i1",
          "url" => "https://example.test/symbol.png",
          "width" => 1, "height" => 1, "content_type" => "image/png",
        }],
        "sounds" => [],
      }
    end

    before do
      # Don't trigger downstream variant preprocessing during unit specs.
      allow(PreprocessDocTileVariantJob).to receive(:perform_async)
    end

    context "by default (include_images not set)" do
      it "creates Image rows as is_private: true" do
        # Down.download should never even be called.
        expect(Down).not_to receive(:download)
        described_class.from_obf(obf_with_image_url, user)
        image = Image.find_by(user: user, label: "hi")
        expect(image).to be_present
        expect(image.is_private).to eq(true)
      end

      it "does NOT attach a Doc for an OBF image entry — binary opt-in is off" do
        allow(Down).to receive(:download)  # safety; should not be called
        expect {
          described_class.from_obf(obf_with_image_url, user)
        }.not_to change { Doc.count }
      end
    end

    context "with import_options include_images: true" do
      # We stub Down.download => nil to short-circuit attach_image_doc cleanly
      # (existing code: nil download → return nil before any Active Storage work).
      # The point of these specs is the GATE — that opt-in flips the call from
      # blocked to attempted — not the downstream attach/storage stack.
      before { allow(Down).to receive(:download).and_return(nil) }

      it "still marks Image rows is_private: true (non-negotiable)" do
        described_class.from_obf(obf_with_image_url, user, nil, nil,
                                 import_options: { include_images: true })
        expect(Image.find_by(user: user, label: "hi").is_private).to eq(true)
      end

      it "calls Down.download for the URL (gate is open)" do
        expect(Down).to receive(:download).with("https://example.test/symbol.png")
        described_class.from_obf(obf_with_image_url, user, nil, nil,
                                 import_options: { include_images: true })
      end
    end

    it "does NOT downgrade an existing public Image found by label match" do
      existing = create(:image, label: "hi", user: user, is_private: false)
      described_class.from_obf(obf_with_image_url, user)
      expect(existing.reload.is_private).to eq(false)
    end
  end

  # NOTE: the old "#to_obf (export)" spec block lived here. Board#to_obf was
  # deleted in favor of Boards::ObfExporter (see
  # spec/services/boards/obf_exporter_spec.rb), which covers the same ground:
  # spec-shaped output, load_board linking, and sound omission.

  describe "#print_grid_layout_for_screen_size" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }

    def add_tile(position:, layout:)
      bi = FactoryBot.create(:board_image, board: board, image: FactoryBot.create(:image, user: user))
      bi.update_columns(position: position, layout: layout)
      bi
    end

    it "returns each tile's cell for the screen size, in position order" do
      add_tile(position: 1, layout: { "lg" => { "i" => "b", "x" => 1, "y" => 0, "w" => 1, "h" => 1 } })
      add_tile(position: 0, layout: { "lg" => { "i" => "a", "x" => 0, "y" => 0, "w" => 1, "h" => 1 } })

      cells = board.reload.print_grid_layout_for_screen_size("lg")

      expect(cells.map { |c| c["i"] }).to eq(%w[a b])
    end

    it "skips tiles with no cell for that screen size" do
      add_tile(position: 0, layout: { "lg" => { "i" => "a", "x" => 0, "y" => 0, "w" => 1, "h" => 1 } })
      add_tile(position: 1, layout: { "sm" => { "i" => "b", "x" => 0, "y" => 0, "w" => 1, "h" => 1 } })

      expect(board.reload.print_grid_layout_for_screen_size("lg").size).to eq(1)
    end

    # Regression: this used to build a plain Array indexed by the GLOBAL
    # board_images primary key and then compact the holes away, so the work and
    # memory for a two-tile board scaled with MAX(board_images.id) across the
    # whole table. api_view calls it three times per board, which is what made
    # serializing a list of boards take seconds in production.
    it "does not scale with the size of the board_images id space" do
      a = add_tile(position: 0, layout: { "lg" => { "i" => "a", "x" => 0, "y" => 0, "w" => 1, "h" => 2 } })
      b = add_tile(position: 1, layout: { "lg" => { "i" => "b", "x" => 1, "y" => 0, "w" => 1, "h" => 1 } })
      a.update_columns(id: 5_000_001)
      b.update_columns(id: 5_000_002)

      cells = board.reload.print_grid_layout_for_screen_size("lg")

      expect(cells.size).to eq(2)
      expect(board.rows_for_screen_size("lg")).to eq(2)
    end

    it "drops the memo when the layout is recalculated" do
      add_tile(position: 0, layout: {})
      expect(board.reload.print_grid_layout_for_screen_size("lg")).to eq([])

      board.calculate_grid_layout_for_screen_size("lg", true)

      expect(board.print_grid_layout_for_screen_size("lg").size).to eq(1)
    end
  end

  describe ".admin_owned_boards" do
    let(:admin_user) { User.find_by(id: User::DEFAULT_ADMIN_ID) || FactoryBot.create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

    it "includes an admin-owned published board regardless of the predefined flag" do
      catalogue_board = FactoryBot.create(:board, user: admin_user, predefined: true, published: true)
      wizard_board = FactoryBot.create(:board, user: admin_user, predefined: false, published: true)

      ids = described_class.admin_owned_boards.pluck(:id)

      expect(ids).to include(catalogue_board.id, wizard_board.id)
    end

    it "excludes an unpublished board, a Menu extraction, an OBF import, and a Board Builder child page" do
      unpublished = FactoryBot.create(:board, user: admin_user, predefined: false, published: false)
      menu_board = FactoryBot.create(:board, user: admin_user, predefined: false, published: true, parent_type: "Menu")
      obf_board = FactoryBot.create(:board, user: admin_user, predefined: false, published: true, obf_id: "abc123")
      builder_child = FactoryBot.create(:board, user: admin_user, predefined: false, published: true,
                                                 settings: { "builder_child" => true })

      ids = described_class.admin_owned_boards.pluck(:id)

      expect(ids).not_to include(unpublished.id, menu_board.id, obf_board.id, builder_child.id)
    end

    it "excludes a published board owned by a regular user" do
      user_board = FactoryBot.create(:board, user: FactoryBot.create(:user), predefined: false, published: true)

      expect(described_class.admin_owned_boards.pluck(:id)).not_to include(user_board.id)
    end
  end

  describe "#public_card_view / .public_board_cards" do
    let(:admin_user) { User.find_by(id: User::DEFAULT_ADMIN_ID) || FactoryBot.create(:admin_user, id: User::DEFAULT_ADMIN_ID) }
    let!(:public_board) do
      FactoryBot.create(:board, user: admin_user, predefined: true, published: true, parent_type: "User")
    end

    it "carries the keys the public board card renders" do
      view = public_board.public_card_view

      expect(view.keys).to contain_exactly(
        :id, :board_id, :slug, :name,
        :display_image_url, :preview_image_url, :preset_display_image_url
      )
      expect(view[:id]).to eq(public_board.id)
      expect(view[:board_id]).to eq(public_board.id)
      expect(view[:name]).to eq(public_board.name)
    end

    # The MySpeak page is unauthenticated. api_view emits in_use_by (a joined
    # list of communicator NAMES) and communicator_account_data (their account
    # ids, names, and avatar URLs); none of that may ride along on a public page.
    it "omits the communicator identities api_view exposes" do
      view = public_board.public_card_view

      expect(view).not_to have_key(:in_use_by)
      expect(view).not_to have_key(:communicator_account_data)
      expect(view).not_to have_key(:user_name)
      expect(view).not_to have_key(:data)
      expect(view).not_to have_key(:settings)
    end

    it "returns one card per public board" do
      cards = described_class.public_board_cards

      expect(cards.map { |c| c[:id] }).to include(public_board.id)
      expect(cards.size).to eq(described_class.public_boards.count)
    end

    it "changes its cache key when a public board is touched" do
      before_key = described_class.public_board_cards_cache_key
      public_board.touch

      expect(described_class.public_board_cards_cache_key).not_to eq(before_key)
    end
  end

  describe "#public_page_card_view" do
    let(:owner) { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: owner, predefined: false, published: true) }

    it "carries the presentational flags the public grids read" do
      view = board.public_page_card_view

      expect(view.keys).to contain_exactly(
        :id, :board_id, :slug, :name,
        :display_image_url, :preview_image_url, :preset_display_image_url,
        :user_id, :predefined, :published,
        :can_edit, :locked, :in_a_public_group
      )
      expect(view[:name]).to eq(board.name)
      expect(view[:published]).to be(true)
      expect(view[:predefined]).to be(false)
    end

    # A User's own public page listed their boards with the full api_view, so
    # every visitor received in_use_by — a joined list of that user's own
    # communicators' names — plus communicator_account_data (ids, names,
    # avatars). The frontend gates both behind `!isPublicGrid && can_edit`, so
    # neither was ever rendered publicly; they were only ever transmitted.
    it "omits the communicator identities api_view exposes" do
      view = board.public_page_card_view

      expect(view).not_to have_key(:in_use_by)
      expect(view).not_to have_key(:communicator_account_data)
      expect(view).not_to have_key(:in_use)
      expect(view).not_to have_key(:user_name)
    end

    it "omits the bulk fields a card never renders" do
      view = board.public_page_card_view

      %i[data settings layout word_list word_sample margin_settings
         large_screen_rows medium_screen_rows small_screen_rows].each do |key|
        expect(view).not_to have_key(key)
      end
    end

    # public_page_view has no viewer, so api_view was already being called with
    # viewing_user = nil and these were false for everyone. Pinned, not derived.
    it "never grants edit affordances" do
      view = board.public_page_card_view

      expect(view[:can_edit]).to be(false)
      expect(view[:locked]).to be(false)
      expect(view[:in_a_public_group]).to be(false)
    end
  end

  describe "#api_view_with_predictive_images audio enqueue" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user, voice: "polly:kevin") }
    let(:image) { FactoryBot.create(:image, label: "hello", user_id: user.id) }
    let!(:board_image) do
      FactoryBot.create(:board_image, board: board, image: image, skip_create_voice_audio: true)
    end

    before do
      # Tile is pinned to a different voice than the board, so the serializer
      # takes the re-enqueue branch, and no file exists for the board's voice.
      board_image.update_columns(voice: "polly:joanna", audio_url: nil)
      allow_any_instance_of(BoardImage).to receive(:audio_url_for_voice).and_return(nil)
      SaveAudioJob.clear
    end

    it "enqueues inline when serializing outside a transaction" do
      board.api_view_with_predictive_images(user, false, "polly:kevin")

      expect(SaveAudioJob.jobs.size).to eq(1)
      expect(SaveAudioJob.jobs.first["args"]).to eq([image.id, "polly:kevin", board_image.id])
    end

    # The builder writes a set and serializes the root inside one transaction,
    # and those tiles are exactly the ones with no audio yet.
    it "holds the enqueue until the enclosing transaction commits" do
      ActiveRecord::Base.transaction do
        board.api_view_with_predictive_images(user, false, "polly:kevin")
        expect(SaveAudioJob.jobs).to be_empty
      end

      expect(SaveAudioJob.jobs.size).to eq(1)
    end

    it "never enqueues when the transaction rolls back" do
      ActiveRecord::Base.transaction do
        board.api_view_with_predictive_images(user, false, "polly:kevin")
        raise ActiveRecord::Rollback
      end

      expect(SaveAudioJob.jobs).to be_empty
    end
  end
end
