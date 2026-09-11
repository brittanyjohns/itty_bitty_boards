# Admin-only entry management for an event's drawing. Today that is just
# removing a staff/test entry from the admin page. #909
class API::Admin::ContestEntriesController < API::Admin::ApplicationController
  before_action :set_event
  before_action :set_contest_entry

  # DELETE /api/admin/events/:event_id/entries/:id
  def destroy
    @contest_entry.destroy!
    render json: { success: true }
  end

  private

  # :event_id may be a slug or a numeric id, same as the events controller.
  def set_event
    @event = Event.find_by(slug: params[:event_id]) || Event.find_by(id: params[:event_id])
    render json: { error: "not_found" }, status: :not_found unless @event
  end

  def set_contest_entry
    return if performed?

    @contest_entry = @event.contest_entries.find_by(id: params[:id])
    render json: { error: "not_found" }, status: :not_found unless @contest_entry
  end
end
