module Admin
  # Admin Board Builder: author a dense AAC board from a word list, review the
  # symbol art, then build it.
  #
  # Three rails are load-bearing and must stay:
  #   1. Preview writes NOTHING. It resolves art through Images::LabelSearch,
  #      never Boards::ImageResolver.resolve/resolve_all — those create a blank
  #      Image row for any label with no match, so a read-only path must not
  #      touch them. A wrong symbol is expensive to fix after the fact, which is
  #      the whole reason the build is two steps.
  #   2. Nothing is written until the plan validates. A bad word list re-renders
  #      the form with exactly what the admin typed.
  #   3. Boards are created unpublished and owned by User::DEFAULT_ADMIN_ID.
  #      Publishing is a separate, confirmed POST, and every member action is
  #      scoped through AdminBoardBuild.builder_boards so it can never reach a
  #      board this page didn't create.
  class BoardBuildsController < Admin::ApplicationController
    MAX_COLUMNS = 12
    MAX_ROWS = 12
    DEFAULT_COLUMNS = 6
    DEFAULT_ROWS = 4
    DEFAULT_VOICE = "polly:kevin".freeze

    before_action :require_seed_admin!
    before_action :set_build, only: %i[show destroy publish unpublish]

    def index
      @builds = AdminBoardBuild.includes(:board, :created_by).recent.limit(100)
    end

    def new
      @form = blank_form
    end

    # Step one. Read-only: resolves what the library would attach to each tile
    # and renders it for a human to look at. Asserted by spec to change neither
    # Board.count nor Image.count.
    def preview
      @form = submitted_form
      @problems = validation_problems(@form)
      return render(:new, status: :unprocessable_entity) if @problems.any?

      @preview = Boards::AdminBuilder::ArtPreview.new(
        labels: @form[:tiles].map { |tile| tile[:label] },
        commercial_safe_only: @form[:commercial_safe_only],
      ).call

      render :preview
    end

    # Step two. The preview round-trip is a hidden-field resubmit, so the plan
    # is parsed and validated again from scratch — never trusted.
    def create
      @form = submitted_form
      @problems = validation_problems(@form)
      return render(:new, status: :unprocessable_entity) if @problems.any?

      build = AdminBoardBuild.create!(
        created_by: current_user,
        status: "pending",
        name: @form[:name],
        topic: @form[:topic].presence,
        voice: @form[:voice],
        columns_count: @form[:columns].to_i,
        rows_count: @form[:rows].to_i,
        commercial_safe_only: @form[:commercial_safe_only],
        plan: { "tiles" => @form[:tiles].map { |tile| tile.transform_keys(&:to_s) } },
      )
      BuildAdminBoardJob.perform_async(build.id)

      redirect_to admin_dashboard_board_build_path(build),
                  notice: "Building “#{build.name}” — it lands unpublished for review."
    end

    def show
      @board = builder_board_for(@build)
      @tiles = @board ? @board.board_images.includes(:image).order(:position) : []
      @missing_art_count = @board ? missing_art_count(@board) : 0
    end

    def publish
      board = builder_board_for(@build)
      return redirect_to(admin_dashboard_board_build_path(@build), alert: "No board to publish yet.") if board.nil?

      if board.board_images.empty?
        return redirect_to admin_dashboard_board_build_path(@build),
                           alert: "This board has no tiles — refusing to publish an empty board."
      end

      board.update!(published: true)
      redirect_to admin_dashboard_board_build_path(@build), notice: "“#{board.name}” is now public."
    end

    def unpublish
      board = builder_board_for(@build)
      return redirect_to(admin_dashboard_board_build_path(@build), alert: "No board to unpublish.") if board.nil?

      board.update!(published: false)
      redirect_to admin_dashboard_board_build_path(@build), notice: "“#{board.name}” is no longer public."
    end

    def destroy
      board = builder_board_for(@build)
      if board&.published?
        return redirect_to admin_dashboard_board_builds_path,
                           alert: "“#{board.name}” is published — unpublish it before deleting."
      end

      name = @build.name
      # The build row first: admin_board_builds.board_id carries a foreign key,
      # so destroying the board while the build still points at it violates it.
      @build.destroy
      board&.destroy
      redirect_to admin_dashboard_board_builds_path, notice: "Deleted “#{name}”."
    end

    private

    def set_build
      @build = AdminBoardBuild.find_by(id: params[:id])
      redirect_to admin_dashboard_board_builds_path, alert: "Board build not found." unless @build
    end

    # A board is only reachable from here if it carries this page's marker, so
    # a hand-edited board_id can't turn publish into a lever on any board.
    def builder_board_for(build)
      return nil if build.board_id.blank?

      AdminBoardBuild.builder_boards.find_by(id: build.board_id)
    end

    # Built boards are owned by the canonical admin (parity with
    # Admin::VideoBoardsController), not whichever admin is signed in.
    def seed_admin
      @seed_admin ||= User.find_by(id: User::DEFAULT_ADMIN_ID)
    end

    def require_seed_admin!
      return if seed_admin

      redirect_to admin_root_path, alert: "No default admin user configured — cannot build boards."
    end

    def missing_art_count(board)
      Image.where(id: board.board_images.select(:image_id)).where.missing(:docs).count
    end

    def voice_values
      @voice_values ||= VoiceService::VOICES.map { |voice| voice[:value] }
    end

    def blank_form
      {
        name: "",
        topic: "",
        voice: DEFAULT_VOICE,
        columns: DEFAULT_COLUMNS.to_s,
        rows: DEFAULT_ROWS.to_s,
        words: "",
        tiles: [],
        commercial_safe_only: true,
        allow_partial_row: false,
      }
    end

    # Keeps the raw submitted strings so a failed submit re-renders exactly what
    # the admin typed. Reads raw params rather than strong params, matching
    # Admin::VideoBoardsController.
    def submitted_form
      words = params[:words].to_s

      {
        name: params[:name].to_s.strip,
        topic: params[:topic].to_s.strip,
        voice: params[:voice].to_s.strip.presence || DEFAULT_VOICE,
        columns: params[:columns].to_s.strip,
        rows: params[:rows].to_s.strip,
        words: words,
        tiles: parse_tiles(words),
        commercial_safe_only: checked?(params[:commercial_safe_only]),
        allow_partial_row: checked?(params[:allow_partial_row]),
      }
    end

    def checked?(value)
      ActiveModel::Type::Boolean.new.cast(value) || false
    end

    # One tile per line: `word`, `word | part_of_speech`, or
    # `word | part_of_speech | tile text`. A textarea rather than N inputs
    # because a dense board is 24-84 words and pasting a list is the job.
    def parse_tiles(words)
      words.to_s.split("\n").filter_map do |line|
        line = line.strip
        next if line.blank?

        label, part_of_speech, display_label = line.split("|", 3).map { |part| part.to_s.strip }
        {
          label: label.to_s,
          part_of_speech: part_of_speech.presence || "default",
          display_label: display_label.presence,
        }.compact
      end
    end

    def validation_problems(form)
      problems = []
      problems << "Give the board a name." if form[:name].blank?
      # VoiceService.normalize_voice passes through any string containing a
      # colon without validating it, so "polly:kevn" would save fine and only
      # fail later at audio synthesis. Constrain to the list.
      problems << "Pick a voice from the list." unless voice_values.include?(form[:voice])

      columns = form[:columns].to_i
      rows = form[:rows].to_i
      problems << "Columns must be between 1 and #{MAX_COLUMNS}." unless columns.between?(1, MAX_COLUMNS)
      problems << "Rows must be between 1 and #{MAX_ROWS}." unless rows.between?(1, MAX_ROWS)
      return problems if problems.any?

      problems + Boards::AdminBuilder::PlanValidator.new(
        tiles: form[:tiles],
        columns: columns,
        rows: rows,
        allow_partial_row: form[:allow_partial_row],
      ).call
    end
  end
end
