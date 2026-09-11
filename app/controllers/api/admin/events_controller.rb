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

  # POST /api/admin/events/:id_or_slug/pick_winner
  #
  # An absent or empty body is valid and means redraw: false. #909
  def pick_winner
    redraw = ActiveModel::Type::Boolean.new.cast(params[:redraw]) || false
    entries = @event.contest_entries.to_a
    current_winner = entries.find(&:winner?)

    if current_winner && !redraw
      return render json: { error: "already_drawn", winner: current_winner.api_view },
                    status: :conflict
    end

    eligible = eligible_entries(entries)
    if eligible.empty?
      return render json: { error: "no_eligible_entries" }, status: :unprocessable_content
    end

    drawn_at = Time.current
    new_winner = eligible.sample

    ContestEntry.transaction do
      if current_winner
        # The previous winner keeps won_at — that's the history — and records
        # when they were redrawn so the CSV shows the full story.
        current_winner.update!(
          winner: false,
          data: entry_data_hash(current_winner).merge("redrawn_at" => drawn_at.iso8601),
        )
      end
      new_winner.update!(winner: true, won_at: drawn_at)
    end

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
    if @event.save
      render json: @event.admin_view, status: :created
    else
      render json: { errors: @event.errors.messages }, status: :unprocessable_content
    end
  end

  # PATCH/PUT /events/1 or /events/1.json
  def update
    if @event.update(event_params)
      render json: @event.reload.admin_view, status: :ok
    else
      render json: { errors: @event.errors.messages }, status: :unprocessable_content
    end
  end

  # DELETE /events/1 or /events/1.json
  def destroy
    @event.destroy!
    render json: { success: true }
  end

  private

  # `data` is jsonb but older rows (and the API's :data param) can hold a JSON
  # string rather than an object. Normalize before merging the redraw stamp.
  def entry_data_hash(entry)
    value = entry.data
    value = (JSON.parse(value) rescue nil) if value.is_a?(String)
    value.is_a?(Hash) ? value : {}
  end

  # Entries that may be drawn: not already a winner of this event, not flagged
  # excluded, not a staff/test address, and — when the event has a lead_source
  # — not somebody who has already won another event in the same series. #909
  def eligible_entries(entries)
    already_won = emails_that_won_elsewhere(@event)
    entries.select { |entry| entry.eligible? && !already_won.include?(entry.email.to_s) }
  end

  # One prize per person across the days of a multi-day series. Keyed on
  # won_at (not `winner`) so a redrawn past winner still can't win again.
  def emails_that_won_elsewhere(event)
    return Set.new if event.lead_source.blank?

    ContestEntry
      .joins(:event)
      .where(events: { lead_source: event.lead_source })
      .where.not(event_id: event.id)
      .where.not(won_at: nil)
      .pluck(:email)
      .map(&:to_s)
      .to_set
  end

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
    params.require(:event).permit(:name, :slug, :date, :lead_source, :time_zone, :promo_code, :promo_code_details)
  end

  def entry_params
    params.require(:contest_entry).permit(:name, :email, :data)
  end
end
