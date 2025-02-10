class API::Admin::WordEventsController < API::Admin::ApplicationController

  # GET /word_events or /word_events.json
  def index
    sort_order = params[:sort_order] || "desc"
    sort_field = params[:sort_field] || "created_at"
    @word_events = WordEvent.where.not(user_id: current_admin.id)
    @word_events = @word_events.order(sort_field => sort_order.to_sym)

    render json: @word_events.map(&:admin_api_view)
  end
end
