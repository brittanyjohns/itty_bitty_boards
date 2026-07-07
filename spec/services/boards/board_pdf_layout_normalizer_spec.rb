require "rails_helper"

RSpec.describe Boards::BoardPdfLayoutNormalizer, type: :service do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user) }

  def tile_for(label)
    described_class.call(board, "lg").find { |t| t["label"] == label }
  end

  def add_tile(image, **attrs)
    create(:board_image, board: board, image: image, skip_create_voice_audio: true, **attrs)
  end

  describe "tile picture resolution" do
    it "renders the tile's real picture" do
      image = create(:image, label: "dog", src_url: "https://cdn.example/dog.png")
      add_tile(image)

      expect(tile_for("dog")["image_url"]).to eq("https://cdn.example/dog.png")
    end

    it "leaves a label-only tile blank instead of borrowing a same-label library image" do
      # The 'I feel' header case: the tile's own image carries no art, and its
      # display_label differs from the underlying image label. A same-label
      # public/admin image WITH art exists in the shared library.
      own = create(:image, label: "tired", src_url: nil, user_id: user.id)
      create(:image, label: "tired", src_url: "https://cdn.example/tired-face.png", user_id: nil)
      board_image = add_tile(own, display_label: "I feel")

      # The normalizer must NOT borrow the library art — a blank result lets the
      # template draw the label as text, matching what the app shows.
      expect(tile_for("I feel")["image_url"]).to be_blank

      # Guard the deliberate divergence: the model helper still borrows, because
      # other callers (Board Builder folder covers, OBF export) rely on that.
      expect(board_image.tile_image_url).to eq("https://cdn.example/tired-face.png")
    end
  end
end
