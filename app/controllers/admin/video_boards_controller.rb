module Admin
  # Interactive version of `lib/tasks/video_demo.rake`: build an unpublished
  # video demo board from a form, review every clip, then publish it.
  #
  # Two rails are load-bearing and must stay:
  #   1. Create never publishes. Publishing is a separate, confirmed POST, and
  #      an empty board can't be published at all.
  #   2. Nothing is written until every row parses. A single bad URL or trim
  #      range re-renders the form with the submitted values intact.
  class VideoBoardsController < Admin::ApplicationController
    SEEDER_SETTING = "video_seeder".freeze
    MAX_COLUMNS = 12

    before_action :require_seed_admin!
    before_action :set_board, only: %i[show destroy publish unpublish]

    def index
      @boards = seeded_boards.includes(:board_images).limit(200)
    end

    def new
      @form = blank_form
    end

    def create
      @form = submitted_form
      @error = validation_error(@form)
      return render(:new, status: :unprocessable_entity) if @error

      board = ActiveRecord::Base.transaction do
        VideoBoards::BoardSeeder.build_board!(board_config(@form), admin: seed_admin)
      end
      redirect_to admin_dashboard_video_board_path(board),
                  notice: "Created unpublished — review every video, then publish."
    end

    def show
      @tiles = @board.board_images.includes(:image).order(:position)
    end

    def publish
      if @board.board_images.empty?
        return redirect_to admin_dashboard_video_board_path(@board),
                           alert: "This board has no tiles — refusing to publish an empty board."
      end

      @board.update!(published: true)
      redirect_to admin_dashboard_video_board_path(@board), notice: "“#{@board.name}” is now public."
    end

    def unpublish
      @board.update!(published: false)
      redirect_to admin_dashboard_video_board_path(@board), notice: "“#{@board.name}” is no longer public."
    end

    def destroy
      if @board.published?
        return redirect_to admin_dashboard_video_boards_path,
                           alert: "“#{@board.name}” is published — unpublish it before deleting."
      end

      name = @board.name
      @board.destroy
      redirect_to admin_dashboard_video_boards_path, notice: "Deleted “#{name}”."
    end

    private

    # Scoped to boards this page created, so the destroy/publish actions can
    # never reach an unrelated board by id.
    def seeded_boards
      Board.where("(settings ->> :key) = 'true'", key: SEEDER_SETTING).order(created_at: :desc)
    end

    def set_board
      @board = seeded_boards.find_by(id: params[:id])
      redirect_to admin_dashboard_video_boards_path, alert: "Video board not found." unless @board
    end

    # Seeded boards are owned by the canonical admin (parity with the rake
    # task), not by whichever admin happens to be signed in.
    def seed_admin
      @seed_admin ||= User.find_by(id: User::DEFAULT_ADMIN_ID)
    end

    def require_seed_admin!
      return if seed_admin

      redirect_to admin_root_path, alert: "No default admin user configured — cannot seed video boards."
    end

    def blank_form
      { name: "", description: "", tags: "", columns: nil, rows: [blank_row, blank_row, blank_row] }
    end

    def blank_row
      { label: "", url: "", start_seconds: "", end_seconds: "" }
    end

    # Keeps the raw submitted strings so a failed create can re-render exactly
    # what the admin typed.
    def submitted_form
      rows = params.fetch(:videos, {}).values.map do |row|
        {
          label: row[:label].to_s.strip,
          url: row[:url].to_s.strip,
          start_seconds: row[:start_seconds].to_s.strip,
          end_seconds: row[:end_seconds].to_s.strip,
        }
      end
      rows = [blank_row] if rows.empty?

      {
        name: params[:name].to_s.strip,
        description: params[:description].to_s.strip,
        tags: params[:tags].to_s.strip,
        columns: params[:columns].presence,
        rows: rows,
      }
    end

    def filled_rows(form)
      form[:rows].reject { |row| row.values.all?(&:blank?) }
    end

    # Returns an error string, or nil when the form is safe to build from. Also
    # stashes the parsed rows on the form so create doesn't parse twice.
    def validation_error(form)
      return "Give the board a name." if form[:name].blank?

      rows = filled_rows(form)
      return "Add at least one video row." if rows.empty?

      if seeded_boards.exists?(name: form[:name]) ||
         VideoBoards::BoardSeeder.board_for(form[:name], seed_admin).persisted?
        return "A board named “#{form[:name]}” already exists. Pick a different name."
      end

      parsed = []
      rows.each_with_index do |row, index|
        position = index + 1
        return "Row #{position}: add a label for the tile." if row[:label].blank?

        youtube_id = YoutubeUrlParser.video_id(row[:url])
        return "Row #{position} (#{row[:label]}): that isn't a recognizable YouTube video URL." unless youtube_id

        # {} means "no trim" and is fine; only nil is a rejection.
        range = BoardImage.parse_video_range(row[:start_seconds], row[:end_seconds])
        if range.nil?
          return "Row #{position} (#{row[:label]}): start/end must be whole seconds, and end must be after start."
        end

        parsed << { label: row[:label], youtube_id: youtube_id, range: range }
      end

      form[:parsed] = parsed
      nil
    end

    def board_config(form)
      videos = form[:parsed]
      columns = form[:columns].to_i
      columns = VideoBoards::BoardSeeder.suggested_columns(videos.size) unless columns.between?(1, MAX_COLUMNS)

      {
        name: form[:name],
        description: form[:description],
        tags: form[:tags].split(",").map(&:strip).reject(&:blank?),
        columns: columns,
        settings: { SEEDER_SETTING => true },
        videos: videos,
      }
    end
  end
end
