class API::FeedbackController < API::ApplicationController
  before_action :authenticate_token!

  def create
    @item = FeedbackItem.new(feedback_params)
    @item.user = current_user
    @item.role = current_user.role || "other"

    if @item.save
      render json: { ok: true }, status: :created
    else
      render json: { ok: false, errors: @item.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def feedback_params
    params.require(:feedback).permit(
      :feedback_type,
      :subject,
      :message,
      :page_url,
      :app_version,
      :platform,
      :device,
      :allow_contact
    )
  end
end
