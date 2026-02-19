# app/controllers/api/page_follows_controller.rb
class API::PageFollowsController < API::ApplicationController
  before_action :authenticate_token!

  # POST /api/page_follows
  def create
    page = Page.find(params.require(:followed_page_id))

    follow = PageFollow.new(
      follower_user: current_user,
      page: page,
    )

    if follow.save
      render json: { ok: true }, status: :created
    else
      render json: { ok: false, errors: follow.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/page_follows/:followed_page_id
  def destroy
    followed_page_id = params[:followed_page_id]

    follow = PageFollow.find_by(
      follower_user_id: current_user.id,
      followed_page_id: followed_page_id,
    )

    # idempotent delete (safe to call even if not following)
    follow&.destroy
    render json: { ok: true }
  end
end
