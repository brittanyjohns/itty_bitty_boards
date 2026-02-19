# app/controllers/api/pages_controller.rb
class API::PagesController < API::ApplicationController
  # If you want anonymous users to see follower_count but not "am_following",
  # remove require_user! and compute am_following only if current_user exists.
  before_action :authenticate_token!, only: [:follow_summary]
  # GET /api/pages/:id/follow_summary
  def follow_summary
    Rails.logger.info "Fetching follow summary for page #{params[:id]} by user #{current_user&.id || "anonymous"}"
    page = Page.find(params[:id])

    follower_count = PageFollow.where(followed_page_id: page.id).count
    am_following = current_user ? PageFollow.exists?(follower_user_id: current_user.id, followed_page_id: page.id) : false

    render json: {
      page_id: page.id,
      follower_count: follower_count,
      am_following: am_following,
    }
  end
end
