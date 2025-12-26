class API::Admin::FeedbackController < API::Admin::ApplicationController

  # GET /admin/feedback or /admin/feedback.json
  def index
    sort_order = params[:sort_order] || "desc"
    sort_field = params[:sort_field] || "created_at"
    @feedback_items = FeedbackItem.includes(:user).all
    @feedback_items = @feedback_items.order(sort_field => sort_order.to_sym).limit(100)
    render json: @feedback_items.map(&:api_view)
  end
end
