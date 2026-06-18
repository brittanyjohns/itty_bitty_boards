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
      expect(board_image.display_label).to eq("hello")
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
end
