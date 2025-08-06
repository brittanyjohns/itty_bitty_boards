class API::Admin::WordEventsController < API::Admin::ApplicationController

  # GET /word_events or /word_events.json
  def index
    sort_order = params[:sort_order] || "desc"
    sort_field = params[:sort_field] || "created_at"
    if sort_field == "board_count"
      sort_field = "created_at"
    end
    @word_events = WordEvent.includes(:user, :child_account).where.not(user_id: current_admin.id)
    @word_events = @word_events.order(sort_field => sort_order.to_sym).limit(100)

    render json: @word_events.map(&:api_view)
  end
end
