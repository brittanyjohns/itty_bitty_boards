class API::Admin::EventsController < API::Admin::ApplicationController
  before_action :set_event, only: %i[show edit update destroy]

  # GET /events or /events.json
  def index
    @events = Event.all.order(created_at: :desc)
    render json: @events
  end

  # GET /events/1 or /events/1.json
  def show
    render json: @event.api_view
  end

  def pick_winner
    @event = Event.find(params[:id])
    @event.contest_entries.update_all(winner: false)
    @contest_entries = @event.contest_entries
    @contest_entry = @contest_entries.sample

    @contest_entry.update(winner: true)
    @event.reload
    render json: @event.api_view
  end

  def download_entries
    @event = Event.find(params[:id])
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
    render json: { success: @event.save ? @event.persisted? : @event.errors }, status: @event.save ? :created : :unprocessable_entity
  end

  # PATCH/PUT /events/1 or /events/1.json
  def update
    respond_to do |format|
      if @event.update(event_params)
        format.json { render :show, status: :ok, location: @event }
      else
        format.json { render json: @event.errors, status: :unprocessable_entity }
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
  def set_event
    @event = Event.includes(:contest_entries).find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def event_params
    params.require(:event).permit(:name, :slug, :date, :promo_code, :promo_code_details)
  end

  def entry_params
    params.require(:contest_entry).permit(:name, :email, :data)
  end
end
