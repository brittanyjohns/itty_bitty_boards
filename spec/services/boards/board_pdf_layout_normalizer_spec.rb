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

      # The normalizer keys its output on display_label, which stays lowercase
      # when defaulted from the image's lowercase matching label.
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

    it "honours a blanked display_image_url even when the image HAS art" do
      # The Core Safety colour-tile case: 'red' is stored with an empty-string
      # display_image_url, which the app treats as "no picture" ("" is truthy in
      # Ruby, so api_view's `||` chain stops there) and draws as the word on a
      # red square. The underlying library image for "red" does have art — an
      # apple — and the PDF used to fall through and print it.
      image = create(:image, label: "red", src_url: "https://cdn.example/apple.png")
      # BoardImage#set_defaults seeds display_image_url from image.src_url on
      # create, so the blank has to be written afterwards — which is also how
      # real tiles get it (a later save from the editor).
      add_tile(image).update_column(:display_image_url, "")

      expect(tile_for("red")["image_url"]).to be_blank
    end

    it "still falls through to the image's art when display_image_url is nil" do
      # The boundary on the other side of the fix: nil is NOT the "no picture"
      # marker — it just means the tile never got its own override — so the
      # underlying image's art must still resolve.
      image = create(:image, label: "cat", src_url: "https://cdn.example/cat.png")
      add_tile(image).update_column(:display_image_url, nil)

      expect(tile_for("cat")["image_url"]).to eq("https://cdn.example/cat.png")
    end
  end
end
