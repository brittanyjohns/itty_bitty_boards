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

    it "defaults the clone to follow its own preview" do
      cloned = board.clone_with_images(user.id)
      expect(cloned.settings["display_follows_preview"]).to be true
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

      # The lookup is case-sensitive — "Apple" and "apple" are treated as different images.
      it "creates a new image for the differently-cased word" do
        words = ["apple", "banana", "cherry"]
        expect {
          board.find_or_create_images_from_word_list(words)
        }.to change(Image, :count).by(3)
      end
    end

    context "when words contain leading/trailing whitespace" do
      # The method does NOT currently strip whitespace — labels are stored as-is.
      # This documents actual behavior; stripping would be a future improvement.
      it "stores the labels with whitespace intact" do
        words = ["  apple  ", "banana", "  cherry"]
        expect {
          board.find_or_create_images_from_word_list(words)
        }.to change(Image, :count).by(3)
        expect(board.images.pluck(:label)).to include("  apple  ", "  cherry", "banana")
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

  describe "#display_image_url with display_follows_preview flag" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }

    before do
      board.update_column(:display_image_url, "https://example.com/user-cover.png")
    end

    context "when the flag is off" do
      it "returns the stored column value" do
        expect(board.display_image_url).to eq("https://example.com/user-cover.png")
      end
    end

    context "when the flag is on but no preview is attached" do
      it "still returns the stored column value (no preview to resolve to)" do
        board.update!(settings: board.settings.merge("display_follows_preview" => true))
        expect(board.display_image_url).to eq("https://example.com/user-cover.png")
      end
    end

    context "when the flag is on and a preview is attached" do
      before do
        board.preview_image.attach(
          io: StringIO.new("png-bytes"),
          filename: "preview.png",
          content_type: "image/png",
        )
        board.update!(settings: board.settings.merge("display_follows_preview" => true))
      end

      # Active Storage signed URLs embed an `expires_at` derived from
      # `Time.current`, so two `.url` calls a millisecond apart produce
      # different strings. Freeze time so both calls share an expiry.
      it "returns the live preview URL" do
        freeze_time do
          expect(board.display_image_url).to eq(board.preview_image_url)
        end
      end

      it "resolves to the new URL after the preview regenerates" do
        original_url = freeze_time { board.display_image_url }
        board.preview_image.purge
        board.preview_image.attach(
          io: StringIO.new("new-png-bytes"),
          filename: "preview.png",
          content_type: "image/png",
        )

        freeze_time do
          expect(board.display_image_url).to eq(board.preview_image_url)
          expect(board.display_image_url).not_to eq(original_url) if board.preview_image_url != original_url
        end
      end
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

  describe "#to_obf (export)" do
    let(:user) { create(:user) }
    let(:linked_board) { create(:board, user: user, name: "Drinks", obf_id: "drinks-123") }
    let(:board) { create(:board, user: user, name: "Home", language: "es") }
    let!(:plain_image) do
      img = create(:image, label: "hello", user: user)
      bi = board.board_images.create!(image_id: img.id, voice: "polly:kevin",
                                      position: 0, skip_create_voice_audio: true)
      bi
    end
    let!(:linked_image) do
      img = create(:image, label: "drinks", user: user)
      bi = board.board_images.create!(image_id: img.id, voice: "polly:kevin",
                                      position: 1, skip_create_voice_audio: true)
      bi.update_columns(predictive_board_id: linked_board.id)
      bi
    end

    before do
      allow_any_instance_of(BoardImage).to receive(:tile_image_url).and_return("https://example.test/img.png")
      allow_any_instance_of(BoardImage).to receive(:audio_url).and_return(nil)
    end

    subject(:obf) { board.to_obf(user) }

    it "matches the OBF spec shape with the expected top-level keys" do
      expect(obf["format"]).to eq(OBF::OBF::FORMAT)
      %w[id locale name grid images buttons sounds].each do |key|
        expect(obf).to have_key(key), "expected exported obf to include #{key}"
      end
    end

    it "uses the board's language for locale (regression: was hardcoded 'en')" do
      expect(obf["locale"]).to eq("es")
    end

    it "emits a load_board on buttons whose BoardImage has a predictive_board_id (regression: links were dropped)" do
      linked_btn = obf["buttons"].find { |b| b["id"] == linked_image.id.to_s }
      expect(linked_btn).to be_present
      expect(linked_btn["load_board"]).to include("id" => "drinks-123", "name" => "Drinks")

      unlinked_btn = obf["buttons"].find { |b| b["id"] == plain_image.id.to_s }
      expect(unlinked_btn["load_board"]).to be_nil
    end

    it "drops sound entries when there's no audio file (regression: emitted id='')" do
      expect(obf["sounds"]).to be_empty
    end
  end
end
