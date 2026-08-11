require "rails_helper"

RSpec.describe BoardImage, type: :model do
  describe "#localized_label" do
    let(:user) { FactoryBot.create(:user) }
    let(:image) do
      FactoryBot.create(:image,
        label: "hello",
        language_settings: { "es" => { "label" => "hola", "display_label" => "Hola" } })
    end
    let(:board) { FactoryBot.create(:board, user: user, language: "en") }
    let(:board_image) { FactoryBot.create(:board_image, board: board, image: image, label: "hello", language: "en") }

    it "returns the board-authored label when the requested language matches" do
      expect(board_image.localized_label("en")).to eq("hello")
    end

    it "delegates to the underlying image's translation when language differs" do
      expect(board_image.localized_label("es")).to eq("hola")
    end

    it "falls back to the stored label when the image has no translation" do
      image.update!(language_settings: {})
      allow(TranslateImageJob).to receive(:perform_async)
      expect(board_image.localized_label("es")).to eq("hello")
    end
  end

  describe "#localized_display_label" do
    let(:user) { FactoryBot.create(:user) }
    let(:image) do
      FactoryBot.create(:image,
        label: "hello",
        language_settings: { "es" => { "label" => "hola", "display_label" => "Hola" } })
    end
    let(:board) { FactoryBot.create(:board, user: user, language: "en") }
    let(:board_image) { FactoryBot.create(:board_image, board: board, image: image, label: "hello", display_label: "Hello", language: "en") }

    it "returns the translated display_label for non-matching language" do
      expect(board_image.localized_display_label("es")).to eq("Hola")
    end

    it "returns the stored display_label when language matches the stored one" do
      expect(board_image.localized_display_label("en")).to eq("Hello")
    end
  end

  describe "#effective_part_of_speech" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }

    it "falls back to \"default\" when the image's part_of_speech is a blank string" do
      image = FactoryBot.create(:image)
      image.update_column(:part_of_speech, "")
      board_image = FactoryBot.create(:board_image, board: board, image: image, part_of_speech: "default")
      expect(board_image.effective_part_of_speech).to eq("default")
    end
  end

  describe "#set_labels" do
    let(:user) { FactoryBot.create(:user) }
    let(:image) do
      FactoryBot.create(:image,
        label: "hello",
        language_settings: { "es" => { "label" => "hola", "display_label" => "Hola" } })
    end
    let(:board) { FactoryBot.create(:board, user: user, language: "es") }

    it "reads the translated label from the string-keyed language_settings jsonb" do
      board_image = FactoryBot.create(:board_image, board: board, image: image, language: "es")
      board_image.set_labels
      expect(board_image.language).to eq("es")
      expect(board_image.label).to eq("hola")
      expect(board_image.display_label).to eq("Hola")
    end

    it "falls back to the English image label when no translation exists" do
      image.update!(language_settings: {})
      board_image = FactoryBot.create(:board_image, board: board, image: image, language: "es")
      board_image.set_labels
      expect(board_image.label).to eq("hello")
      # Non-English boards get sentence case, not English Title Case.
      expect(board_image.display_label).to eq("Hello")
    end

    # An "en" entry is Image#translate_to output for the language the label was
    # already in — defaulted text, not authored styling. Taking it verbatim is
    # what let "You"/"All Done" skip the normalizer and land on a fresh board.
    context "with an English language_settings entry" do
      let(:english_board) { FactoryBot.create(:board, user: user, language: "en") }

      it "case-normalizes it instead of using it verbatim" do
        image = FactoryBot.create(:image, label: "want", part_of_speech: "verb",
                                          language_settings: { "en" => { "label" => "want", "display_label" => "Want" } })
        board_image = FactoryBot.create(:board_image, board: english_board, image: image, language: "en")
        board_image.set_labels

        expect(board_image.display_label).to eq("want")
      end

      it "folds a capital the normalizer could never have produced" do
        image = FactoryBot.create(:image, label: "all done", part_of_speech: "social",
                                          language_settings: { "en" => { "label" => "all done", "display_label" => "All Done" } })
        board_image = FactoryBot.create(:board_image, board: english_board, image: image, language: "en")
        board_image.set_labels

        expect(board_image.display_label).to eq("all done")
      end

      it "still keeps deliberate casing and the standalone pronoun" do
        image = FactoryBot.create(:image, label: "my ipad", part_of_speech: "noun",
                                          language_settings: { "en" => { "label" => "my ipad", "display_label" => "My iPad" } })
        board_image = FactoryBot.create(:board_image, board: english_board, image: image, language: "en")
        board_image.set_labels

        expect(board_image.display_label).to eq("my iPad")
      end

      it "leaves a non-English translation verbatim" do
        board_image = FactoryBot.create(:board_image, board: board, image: image, language: "es")
        board_image.set_labels

        expect(board_image.display_label).to eq("Hola")
      end
    end
  end

  describe "display_label casing on create" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user, language: "en") }

    def tile_for(image, **attrs)
      FactoryBot.create(:board_image, board: board, image: image, **attrs)
    end

    it "leaves a label defaulted from the image lowercase" do
      image = FactoryBot.create(:image, label: "swing")
      tile = tile_for(image)

      expect(tile.display_label).to eq("swing")
      expect(tile.label).to eq("swing")
    end

    it "leaves every word of a multi-word label lowercase" do
      image = FactoryBot.create(:image, label: "all done")
      tile = tile_for(image)

      expect(tile.display_label).to eq("all done")
      expect(tile.label).to eq("all done")
    end

    it "gives tiles created through different paths the same casing" do
      via_direct_create = FactoryBot.create(:image, label: "faster")
      via_add_image = FactoryBot.create(:image, label: "higher")

      direct_tile = tile_for(via_direct_create)
      board.add_image(via_add_image.id)
      added_tile = board.board_images.reload.find_by(image_id: via_add_image.id)

      expect([direct_tile.display_label, added_tile.display_label]).to eq(%w[faster higher])
    end

    it "keeps an explicitly supplied display_label exactly as given" do
      image = FactoryBot.create(:image, label: "ipad")
      tile = tile_for(image, display_label: "iPad")

      expect(tile.display_label).to eq("iPad")
      expect(tile.label).to eq("ipad")
    end

    it "carries brand and acronym casing through from the image's display_label" do
      image = FactoryBot.create(:image, label: "TV")
      tile = tile_for(image)

      # The Image split the two roles at write time: "tv" is the matching key,
      # "TV" is the display text. The tile inherits each into its counterpart,
      # and CaseNormalizer leaves the deliberate casing alone.
      expect(image.label).to eq("tv")
      expect(image.display_label).to eq("TV")

      expect(tile.display_label).to eq("TV")
      expect(tile.label).to eq("tv")
    end

    it "sentence cases whole-utterance phrase tiles" do
      image = FactoryBot.create(:image, label: "i want more", part_of_speech: "phrase")
      tile = tile_for(image)

      expect(tile.display_label).to eq("I want more")
      expect(tile.label).to eq("i want more")
    end

    it "does not apply English Title Case to a non-English board" do
      spanish_board = FactoryBot.create(:board, user: user, language: "es")
      image = FactoryBot.create(:image, label: "todo listo")
      tile = FactoryBot.create(:board_image, board: spanish_board, image: image, language: "es")

      expect(tile.display_label).to eq("Todo listo")
      expect(tile.label).to eq("todo listo")
    end

    it "normalizes the label defaulted through Board#add_image" do
      image = FactoryBot.create(:image, label: "faster")
      board.add_image(image.id)

      tile = board.board_images.reload.find_by(image_id: image.id)
      expect(tile.display_label).to eq("faster")
      expect(tile.label).to eq("faster")
    end
  end

  describe "#api_view" do
    let(:user) { FactoryBot.create(:user) }
    let(:image) do
      FactoryBot.create(:image,
        label: "hello",
        language_settings: { "es" => { "label" => "hola", "display_label" => "Hola" } })
    end
    let(:board) { FactoryBot.create(:board, user: user, language: "en") }
    let(:board_image) { FactoryBot.create(:board_image, board: board, image: image, label: "hello", display_label: "Hello", language: "en") }

    it "returns English label when the viewing user prefers English" do
      user.settings ||= {}
      user.settings["voice"] = { "language" => "en-US" }
      user.save!

      view = board_image.api_view(user)
      expect(view[:label]).to eq("hello")
      expect(view[:display_label]).to eq("Hello")
    end

    it "returns translated label when the viewing user prefers Spanish" do
      user.settings ||= {}
      user.settings["voice"] = { "language" => "es-US" }
      user.save!

      view = board_image.api_view(user)
      expect(view[:label]).to eq("hola")
      expect(view[:display_label]).to eq("Hola")
    end
  end

  describe "voice audio enqueue (after_create_commit)" do
    let(:user) { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }
    let(:image) { FactoryBot.create(:image, label: "hello", user_id: user.id) }

    before do
      # No pre-existing audio for the voice -> the callback takes the
      # SaveAudioJob branch.
      allow_any_instance_of(BoardImage).to receive(:audio_url_for_voice).and_return(nil)
      SaveAudioJob.clear
    end

    it "defers SaveAudioJob until the enclosing transaction commits" do
      # Board Builder clones a whole linked set in one transaction; an
      # after_create enqueue let Sidekiq run SaveAudioJob before the row was
      # visible ("BoardImage with ID ... not found") and the tile shipped
      # without audio.
      ActiveRecord::Base.transaction do
        FactoryBot.create(:board_image, board: board, image: image)
        expect(SaveAudioJob.jobs).to be_empty
      end
      expect(SaveAudioJob.jobs.size).to eq(1)
    end

    it "does not enqueue when the transaction rolls back" do
      ActiveRecord::Base.transaction do
        FactoryBot.create(:board_image, board: board, image: image)
        raise ActiveRecord::Rollback
      end
      expect(SaveAudioJob.jobs).to be_empty
    end

    it "respects skip_create_voice_audio" do
      FactoryBot.create(:board_image, board: board, image: image, skip_create_voice_audio: true)
      expect(SaveAudioJob.jobs).to be_empty
    end
  end

  describe "#tile_image_url" do
    let(:user)  { FactoryBot.create(:user) }
    let(:board) { FactoryBot.create(:board, user: user) }
    let(:image) { FactoryBot.create(:image, user: user) }
    let(:board_image) do
      FactoryBot.create(:board_image, board: board, image: image, skip_create_voice_audio: true)
    end

    it "returns display_image_url when present" do
      board_image.update_column(:display_image_url, "https://cdn.example.com/tile.webp")
      expect(board_image.tile_image_url).to eq("https://cdn.example.com/tile.webp")
    end

    it "falls back to admin image src_url when all else is blank" do
      admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || FactoryBot.create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      admin_image = FactoryBot.create(:image, label: image.label, user: admin)
      admin_image.update_column(:src_url, "https://cdn.example.com/admin_fallback.webp")

      board_image.update_column(:display_image_url, nil)
      image.update_columns(src_url: nil)

      expect(board_image.tile_image_url(user)).to eq("https://cdn.example.com/admin_fallback.webp")
    end

    it "does not hit the admin fallback when display_image_url is present" do
      board_image.update_column(:display_image_url, "https://cdn.example.com/user_pick.webp")
      expect(Image).not_to receive(:find_by).with(hash_including(user_id: [nil, User::DEFAULT_ADMIN_ID]))
      expect(board_image.tile_image_url(user)).to eq("https://cdn.example.com/user_pick.webp")
    end
  end
  describe "#is_audio_current?" do
    let(:board_image) { create(:board_image) }
    let(:attachment) do
      board_image.audio_files.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/sample.mp3")),
        filename: "juice-custom-010125000000-abc123.mp3", content_type: "audio/mpeg",
      )
      board_image.reload.audio_files_attachments.order(:id).last
    end

    # The Disk service signs its URLs with an expiry, so the URL stored on the
    # tile never string-matches a freshly generated one for the same blob. That
    # is what drives the "in use" marker, so it compares blobs instead.
    it "recognises a stored Disk-service URL for the same blob" do
      ActiveStorage::Current.url_options = { host: "localhost", port: 4000, protocol: "http" }
      stored = attachment.url

      expect(board_image.is_audio_current?(attachment, stored)).to be(true)
    end

    it "does not match a URL for a different blob" do
      ActiveStorage::Current.url_options = { host: "localhost", port: 4000, protocol: "http" }
      other = create(:board_image)
      other.audio_files.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/sample.mp3")),
        filename: "water-custom-010125000000-zzz999.mp3", content_type: "audio/mpeg",
      )
      other_url = other.reload.audio_files_attachments.order(:id).last.url

      expect(board_image.is_audio_current?(attachment, other_url)).to be(false)
    end

    it "is false when the record plays nothing" do
      expect(board_image.is_audio_current?(attachment, "")).to be(false)
    end
  end
end
