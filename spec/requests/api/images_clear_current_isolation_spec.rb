require "rails_helper"

# Clearing a picture is a library fan-out like any other: the `update_all`
# branch used to nil display_image_url on every tile of a SHARED Image across
# every account.
RSpec.describe "POST /api/images/:id/clear_current — board isolation", type: :request do
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) ||
      create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end
  let!(:owner) { create(:user) }
  let!(:stranger) { create(:user) }

  let!(:image) { create(:image, user: admin, label: "apple", is_private: false) }
  let!(:doc) { create(:doc, documentable: image, user: admin, current: true) }

  let!(:owner_board) { create(:board, user: owner) }
  let!(:stranger_board) { create(:board, user: stranger) }
  let(:url) { "https://cdn.example.com/apple.webp" }

  before do
    image.update_columns(src_url: url)
    [owner_board, stranger_board].each { |b| b.add_image(image.id) }
    image.board_images.reset
  end

  def tile_on(board)
    image.board_images.find_by(board_id: board.id)
  end

  def clear(as:, params: {})
    post "/api/images/#{image.id}/clear_current",
         params: params.to_json,
         headers: auth_headers(as).merge("CONTENT_TYPE" => "application/json")
  end

  it "clears the caller's own tiles" do
    clear(as: owner, params: { update_all: true })

    expect(response).to have_http_status(:ok)
    expect(tile_on(owner_board).reload.display_image_url).to be_nil
  end

  it "does not clear a stranger's tiles" do
    clear(as: owner, params: { update_all: true })

    expect(tile_on(stranger_board).reload.display_image_url).to eq(url)
  end

  it "leaves a deliberately hidden tile hidden" do
    tile_on(owner_board).update_column(:display_image_url, "")

    clear(as: owner, params: { update_all: true })

    expect(tile_on(owner_board).reload.display_image_url).to eq("")
  end

  # docs.for_user includes user_id [nil, DEFAULT_ADMIN_ID] rows, so this used
  # to let any user blank the shared library's default.
  it "does not clear the library default on someone else's image" do
    clear(as: owner, params: { update_all: true })

    expect(doc.reload.current).to be(true)
  end

  it "lets an admin clear the library default" do
    clear(as: admin, params: { update_all: true })

    expect(doc.reload.current).to be(false)
  end

  it "does not blow up when no board_id is given" do
    clear(as: owner)

    expect(response).to have_http_status(:ok)
  end
end
