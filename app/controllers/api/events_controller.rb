class API::EventsController < API::ApplicationController
  skip_before_action :authenticate_token!

  def show
    @event = Event.find_by(slug: params[:slug])
    if @event.nil?
      render json: { error: "Event not found" }, status: :not_found
      return
    end
    render json: @event.api_view
  end

  def save_entry
    @event = Event.find_by(slug: params[:slug])
    new_entry = @event.contest_entries.create(entry_params)
    if new_entry.persisted?
      render json: { success: true, entry: new_entry.api_view }, status: :created
    else
      render json: { success: false, errors: new_entry.errors }, status: :unprocessable_entity
    end
  end

  private

  def entry_params
    params.require(:contest_entry).permit(:name, :email, :data)
  end

  def event_params
    params.require(:event).permit(:name, :slug, :date)
  end
end
