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

  def discover
    limit = params[:limit].presence&.to_i || 12
    limit = 50 if limit > 50 # safety cap

    # IDs of pages current user already follows
    followed_ids = PageFollow
      .where(follower_user_id: current_user.id)
      .select(:followed_page_id)

    # Exclude user's own page (if profileable is User)
    own_page_id = Profile.where(profileable: current_user).pluck(:id).first

    pages = Page.public_pages
      .where.not(id: followed_ids)
      .where.not(id: own_page_id)
      .left_joins(:page_follows)
      .select(
        "profiles.*,
         COUNT(page_follows.id) AS follower_count"
      )
      .group("profiles.id")
      .order("follower_count DESC")
      .limit(limit)

    render json: {
      items: pages.map { |p| page_suggestion_json(p) },
      next_cursor: nil,
    }
  end

  private

  def page_suggestion_json(page)
    {
      type: "page_suggestion",
      page: {
        id: page.id,
        title: page.try(:name) || page.try(:title),
        name: page.try(:username) || page.try(:slug),
        slug: page.try(:slug),
        avatar_url: page.try(:avatar_url),
        headline: page.try(:headline) || page.try(:intro),
      },
      follower_count: page.attributes["follower_count"].to_i,
      am_following: false,
      reason: nil,
    }
  end
end
