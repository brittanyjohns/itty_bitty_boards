module Admin
  class EventsController < Admin::ApplicationController
    def index
      @events = Event.order(created_at: :desc)
    end

    def show
      @event = Event.includes(:contest_entries).find(params[:id])
      @contest_entries = @event.contest_entries.order(name: :asc)
      @qr_data_url = Boards::AssetRendering.qr_data_url_for(@event.public_url, size: 240)
    end

    def new
      @event = Event.new
    end

    def create
      @event = Event.new(event_params)
      if @event.save
        redirect_to admin_dashboard_event_path(@event), notice: "Event created."
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit
      @event = Event.find(params[:id])
    end

    def update
      @event = Event.find(params[:id])
      if @event.update(event_params)
        redirect_to admin_dashboard_event_path(@event), notice: "Event updated."
      else
        render :edit, status: :unprocessable_content
      end
    end

    def pick_winner
      @event = Event.find(params[:id])
      @event.contest_entries.update_all(winner: false)
      winner = @event.contest_entries.sample

      if winner
        winner.update(winner: true)
        redirect_to admin_dashboard_event_path(@event), notice: "Winner picked: #{winner.name} (#{winner.email})."
      else
        redirect_to admin_dashboard_event_path(@event), alert: "No entries to pick a winner from."
      end
    end

    def download_entries
      @event = Event.find(params[:id])
      entries = @event.contest_entries.order(name: :asc)
      send_data entries.to_csv,
                filename: "#{@event.name.parameterize}-entries-#{Time.zone.now.strftime("%d%m%Y%H%M")}.csv",
                type: "text/csv"
    end

    private

    def event_params
      params.require(:event).permit(:name, :slug, :date, :promo_code, :promo_code_details)
    end
  end
end
