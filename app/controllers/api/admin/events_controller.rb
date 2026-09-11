class API::Admin::EventsController < API::Admin::ApplicationController
  before_action :set_event, only: %i[show edit update destroy pick_winner download_entries]

  # GET /events or /events.json
  def index
    @events = Event.all.order(created_at: :desc)
    render json: @events
  end

  # GET /events/1 or /events/1.json
  def show
    render json: @event.admin_view
  end

  def pick_winner
    @event.contest_entries.update_all(winner: false)
    @contest_entries = @event.contest_entries
    @contest_entry = @contest_entries.sample

    @contest_entry.update(winner: true)
    @event.reload
    render json: @event.admin_view
  end

  def download_entries
    @contest_entries = @event.contest_entries.order(name: :asc)
    send_data @contest_entries.to_csv, filename: "#{@event.name.parameterize}-entries-#{DateTime.now.strftime("%d%m%Y%H%M")}.csv", type: "text/csv"
  end

  # GET /events/new
  def new
    @event = Event.new
  end

  # GET /events/1/edit
  def edit
  end

  # POST /events or /events.json
  def create
    @event = Event.new(event_params)
    render json: { success: @event.save ? @event.persisted? : @event.errors }, status: @event.save ? :created : :unprocessable_content
  end

  # PATCH/PUT /events/1 or /events/1.json
  def update
    respond_to do |format|
      if @event.update(event_params)
        format.json { render :show, status: :ok, location: @event }
      else
        format.json { render json: @event.errors, status: :unprocessable_content }
      end
    end
  end

  # DELETE /events/1 or /events/1.json
  def destroy
    @event.destroy!
    render json: { success: true }
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  # The frontend admin page is routed by slug, so :id may be either a slug or
  # a numeric id. Never raises — an unknown value renders 404. #908
  def set_event
    scope = Event.includes(:contest_entries)
    @event = scope.find_by(slug: params[:id]) || scope.find_by(id: params[:id])
    render json: { error: "not_found" }, status: :not_found unless @event
  end

  # Only allow a list of trusted parameters through.
  def event_params
    params.require(:event).permit(:name, :slug, :date, :promo_code, :promo_code_details)
  end

  def entry_params
    params.require(:contest_entry).permit(:name, :email, :data)
  end
end
