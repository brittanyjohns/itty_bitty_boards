# spec/requests/api/board_images_use_board_preview_spec.rb
#
# "Use board preview" (data["use_board_preview"]) makes the tile serializers
# show the linked board's rendered preview in place of the tile's picture. The
# tile editor saves by posting the whole tile back, whose display_image_url is
# that RESOLVED picture — so without a guard, one ordinary save would pin the
# preview into the tile's own column and switching the toggle off would no
# longer restore the original picture.

require "rails_helper"

RSpec.describe "BoardImages use_board_preview", type: :request do
  before do
    allow_any_instance_of(API::ApplicationController)
      .to receive(:authenticate_token!).and_return(true)
    allow_any_instance_of(API::ApplicationController)
      .to receive(:current_user).and_return(user)

    target_id = target.id
    url = preview_url
    allow_any_instance_of(Board).to receive(:preview_image_url).and_wrap_original do |original|
      original.receiver.id == target_id ? url : original.call
    end
  end

  let!(:user)       { create(:user) }
  let!(:board)      { create(:board, user: user) }
  let!(:target)     { create(:board, user: user, name: "Food") }
  let!(:image)      { create(:image, user: user, label: "food") }
  let(:tile_art)    { "https://example.com/food.png" }
  let(:preview_url) { "https://example.com/previews/food-board.png" }
  let!(:board_image) do
    create(:board_image, board: board, image: image, predictive_board_id: target.id).tap do |bi|
      bi.update_columns(display_image_url: tile_art, data: { "mute_name" => true, "use_board_preview" => true })
    end
  end

  def put_tile(attrs)
    put "/api/board_images/#{board_image.id}", params: { board_image: attrs }, as: :json
  end

  it "turns the toggle on and off through the data merge, keeping the other data keys" do
    put_tile(data: { use_board_preview: false })

    expect(response).to have_http_status(:ok)
    expect(board_image.reload.data).to include("use_board_preview" => false, "mute_name" => true)
    expect(board_image.linked_board_preview_url).to be_nil
  end

  it "does not pin the linked board's preview into the tile's own picture" do
    put_tile(label: "food", src: preview_url, display_image_url: preview_url,
             data: { use_board_preview: true })

    expect(response).to have_http_status(:ok)
    expect(board_image.reload.display_image_url).to eq(tile_art)
  end

  it "still saves a picture that is not the linked board's preview" do
    put_tile(display_image_url: "https://example.com/uploads/my-food.png")

    expect(response).to have_http_status(:ok)
    expect(board_image.reload.display_image_url).to eq("https://example.com/uploads/my-food.png")
  end
end
