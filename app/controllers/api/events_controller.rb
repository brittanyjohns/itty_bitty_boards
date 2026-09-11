class API::EventsController < API::ApplicationController
  skip_before_action :authenticate_token!
  before_action :set_event

  def show
    render json: @event.public_view
  end

  def save_entry
    new_entry = @event.contest_entries.create(entry_params)
    if new_entry.persisted?
      render json: { success: true, entry: new_entry.api_view }, status: :created
    else
      render json: { success: false, errors: new_entry.errors.messages }, status: :unprocessable_content
    end
  end

  private

  # Unknown slug is a 404, never a 500. #908
  def set_event
    @event = Event.find_by(slug: params[:slug])
    render json: { error: "not_found" }, status: :not_found unless @event
  end

  def entry_params
    params.require(:contest_entry).permit(:name, :email, :data)
  end

  def event_params
    params.require(:event).permit(:name, :slug, :date)
  end
end
