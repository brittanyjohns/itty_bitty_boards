require "rails_helper"

# The board's cover is "the first button that carried its own picture", and the
# variable holding it is sticky across the button loop by design. It was also
# being handed to every tile, so a button with no image data of its own got the
# PREVIOUS button's picture. BoardImage#set_defaults used to overwrite the tile's
# display_image_url on create, which masked it; now that a non-nil value is the
# pin, the wrong URL would stick.
RSpec.describe "Board.from_obf tile art", type: :model do
  let(:user) { create(:user) }

  let(:obf) do
    {
      "id" => "core",
      "name" => "Core",
      "buttons" => [
        { "id" => "b1", "label" => "apple", "image_id" => "i1" },
        { "id" => "b2", "label" => "banana", "image_id" => nil },
      ],
      "grid" => { "rows" => 1, "columns" => 2, "order" => [%w[b1 b2]] },
      "images" => [{ "id" => "i1", "url" => "https://cdn.example.com/apple.png", "content_type" => "image/png" }],
    }
  end

  before do
    # A 1x1 PNG, enough for Active Storage to attach.
    png = Base64.decode64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
    )
    allow(Down).to receive(:download).and_return(StringIO.new(png))
  end

  it "does not give a picture-less button the previous button's picture" do
    board, = Board.from_obf(obf, user, nil, nil, import_options: { include_images: true })

    apple = board.board_images.find_by(label: "apple")
    banana = board.board_images.find_by(label: "banana")

    expect(apple.display_image_url).to eq("https://cdn.example.com/apple.png")
    expect(banana.display_image_url).not_to eq("https://cdn.example.com/apple.png")
  end

  it "still uses the first button with a picture as the board's cover" do
    board, = Board.from_obf(obf, user, nil, nil, import_options: { include_images: true })

    expect(board.display_image_url).to eq("https://cdn.example.com/apple.png")
  end
end
