require "rails_helper"

# IDOR: POST /api/boards/:id/regenerate_images was covered by
# check_board_editable! and check_marketplace_edit_confirmed! but by NO
# ownership check — User#board_editable? returns true for a board you don't own
# (it measures the PLAN lock, not permission). Any signed-in user could name
# another user's board_image_ids and spend their OWN AI credits to overwrite
# that board's tile artwork.
#
# The same gap existed on every sibling AI/mutating action in that list.
# #add_image is deliberately excluded: it is the one board write a COMMUNICATOR
# may make, scoped by check_communicator_board_access! instead.
RSpec.describe "API::Boards#regenerate_images IDOR", type: :request do
  let!(:user)       { create(:user) }
  let!(:other_user) { create(:user) }
  let!(:admin)      { create(:admin_user) }

  let!(:board)       { create(:board, user: user) }
  let!(:board_image) { create(:board_image, board: board) }

  before do
    allow(GenerateImagesJob).to receive(:perform_async)
    [user, other_user].each do |u|
      reset_user_credits!(u)
      u.update_columns(topup_credits_balance: 100)
    end
  end

  def regenerate(as:, target: board)
    post "/api/boards/#{target.id}/regenerate_images",
         params: { board_image_ids: [board_image.id] },
         headers: auth_headers(as),
         as: :json
  end

  it "lets the owner regenerate their own board's tile art" do
    expect(GenerateImagesJob).to receive(:perform_async)

    regenerate(as: user)

    expect(response).to have_http_status(:ok)
  end

  # The board is unpublished, so the non-owner can't see it at all and gets the
  # same generic 404 #show gives — board ids are sequential, and a permission
  # answer would confirm the row exists. Once the board IS visible to them the
  # answer becomes 403; both are covered in boards_write_permission_spec.rb.
  it "refuses a signed-in user who does not own the board" do
    expect(GenerateImagesJob).not_to receive(:perform_async)

    regenerate(as: other_user)

    expect(response).to have_http_status(:not_found)
    expect(JSON.parse(response.body)["error"]).to eq("Board not found")
  end

  it "spends none of the non-owner's credits" do
    expect { regenerate(as: other_user) }
      .not_to change { CreditService.balance(other_user.reload)[:total] }

    expect(other_user.credit_transactions.count).to eq(0)
  end

  it "lets an admin regenerate another user's board (cross-user access preserved)" do
    regenerate(as: admin)

    expect(response).to have_http_status(:ok)
  end

  it "still 404s a board that doesn't exist rather than 500ing on the ownership check" do
    post "/api/boards/0/regenerate_images",
         params: { board_image_ids: [board_image.id] },
         headers: auth_headers(user),
         as: :json

    expect(response).to have_http_status(:not_found)
  end

  # The gap was never specific to regenerate_images — it covered every mutating
  # action that check_board_editable! guards, so the fix is swept rather than
  # spot-checked.
  describe "the sibling mutating actions" do
    {
      "post /save_layout" => [:post, "save_layout"],
      "post /rearrange_images" => [:post, "rearrange_images"],
      "put /recategorize_images" => [:put, "recategorize_images"],
      "put /update_to_default_docs" => [:put, "update_to_default_docs"],
      "put /set_colors" => [:put, "set_colors"],
      "put /set_display_image" => [:put, "set_display_image"],
      "put /update_preset_display_image" => [:put, "update_preset_display_image"],
      "post /format_with_ai" => [:post, "format_with_ai"],
      "put /associate_image" => [:put, "associate_image"],
      "put /associate_images" => [:put, "associate_images"],
      "post /remove_image" => [:post, "remove_image"],
      "post /generate_preview_image" => [:post, "generate_preview_image"],
    }.each do |label, (verb, action)|
      it "refuses a non-owner on #{label}" do
        public_send(verb, "/api/boards/#{board.id}/#{action}",
                    headers: auth_headers(other_user),
                    as: :json)

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
