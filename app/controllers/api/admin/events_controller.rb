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
    params.require(:event).permit(:name, :slug, :date)
  end

  def entry_params
    params.require(:contest_entry).permit(:name, :email, :data)
  end
end
