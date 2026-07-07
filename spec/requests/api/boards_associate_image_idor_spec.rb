require "rails_helper"

# Issue #26 (IDOR): PUT /api/boards/:id/associate_image loaded the image with a
# bare `Image.find(params[:image_id])`. A user may add their own image or any
# public library image to a board, but must not be able to reference another
# user's PRIVATE image by id. These specs prove the private-image case now 404s
# while the shared library stays usable.
RSpec.describe "API::Boards#associate_image IDOR", type: :request do
  let!(:user)       { create(:user) }
  let!(:other_user) { create(:user) }
  let!(:admin)      { create(:admin_user) }

  let!(:board) { create(:board, user: user) }

  let!(:other_private_image) { create(:image, user: other_user, is_private: true) }
  let!(:public_image)        { create(:image, user: other_user, is_private: false) }
  let!(:own_image)           { create(:image, user: user, is_private: true) }

  it "404s when adding another user's PRIVATE image" do
    put "/api/boards/#{board.id}/associate_image",
        params: { image_id: other_private_image.id },
        headers: auth_headers(user)
    expect(response).to have_http_status(:not_found)
  end

  it "allows adding a PUBLIC library image (no regression)" do
    put "/api/boards/#{board.id}/associate_image",
        params: { image_id: public_image.id },
        headers: auth_headers(user)
    expect(response).not_to have_http_status(:not_found)
  end

  it "allows adding the caller's own image" do
    put "/api/boards/#{board.id}/associate_image",
        params: { image_id: own_image.id },
        headers: auth_headers(user)
    expect(response).not_to have_http_status(:not_found)
  end

  it "lets an admin add another user's private image (cross-user access preserved)" do
    admin_board = create(:board, user: admin)
    put "/api/boards/#{admin_board.id}/associate_image",
        params: { image_id: other_private_image.id },
        headers: auth_headers(admin)
    expect(response).not_to have_http_status(:not_found)
  end
end
