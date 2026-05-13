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
end
