require "rails_helper"

# Publish cascade: publishing or unpublishing a Board Builder root cascades to
# every member board of its builder BoardGroup, behind a 409 warn+confirm.
RSpec.describe "API::Boards publish cascade", type: :request do
  let(:admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  def update_board(target, as:, params:)
    put "/api/boards/#{target.id}", params: params, headers: auth_headers(as)
  end

  describe "unpublishing a plain board" do
    let(:board) { create(:board, user: admin, published: true) }

    it "persists published=false" do
      update_board(board, as: admin, params: { board: { published: false } })
      expect(response).to have_http_status(:ok)
      expect(board.reload.published).to be false
    end
  end
end
