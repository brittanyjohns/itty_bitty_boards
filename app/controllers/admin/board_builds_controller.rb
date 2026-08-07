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
    # Marks the field in a word-list line that names the page a tile opens.
    LINK_TOKEN = ">".freeze

    before_action :require_seed_admin!
    before_action :set_build, only: %i[show destroy publish unpublish]

    def index
      @builds = AdminBoardBuild.includes(:board, :created_by).recent.limit(100)
    end

    def new
      @form = blank_form
    end

    # Optional step zero. Drafts a word list into the form and stops there —
    # the draft is never fed to a preview or a build on its own. A human edits
    # it, then previews the art, then builds.
    def draft
      @form = submitted_form
      # Topic steers the draft and, later, every art prompt, so infer it from
      # the board rather than making it a prerequisite — "Draft with AI" then
      # works from a name alone. Gated on the topic ONLY: audience is genuinely
      # optional to the drafter, and spending a second API call to fill it in
      # when the topic is already known buys nothing. It gets filled anyway when
      # the topic call runs, since that answers both.
      @form = @form.merge(suggested_context(@form)) if @form[:topic].blank?
      @problems = draft_problems(@form)
      return render(:new, status: :unprocessable_entity) if @problems.any?

      tiles = Boards::AdminBuilder::WordListDrafter.new(
        topic: @form[:topic],
        columns: @form[:columns].to_i,
        rows: @form[:rows].to_i,
        audience: @form[:audience],
      ).call

      @form = @form.merge(words: tiles_to_words(tiles), tiles: tiles)
      flash.now[:notice] = draft_notice(tiles, @form)
      render :new
    rescue Boards::AdminBuilder::WordListDrafter::GenerationError => e
      @problems = ["Couldn't draft a word list: #{e.message}"]
      render :new, status: :unprocessable_entity
    rescue Boards::AdminBuilder::ContextSuggester::GenerationError => e
      @problems = ["Couldn't work out the topic: #{e.message}"]
      render :new, status: :unprocessable_entity
    end

    # Fills in topic and audience on their own, so they can be read and edited
    # before a whole word list is drafted from them.
    def suggest
      @form = submitted_form
      if @form[:name].blank? && @form[:words].strip.blank?
        @problems = ["Give the board a name, or some words, to work the topic out from."]
        return render(:new, status: :unprocessable_entity)
      end

      @form = @form.merge(suggest_context(@form))
      flash.now[:notice] = "Suggested a topic and audience — edit them, or draft a word list."
      render :new
    rescue Boards::AdminBuilder::ContextSuggester::GenerationError => e
      @problems = ["Couldn't suggest a topic: #{e.message}"]
      render :new, status: :unprocessable_entity
    end

    # Step one. Read-only: resolves what the library would attach to each tile
    # and renders it for a human to look at. Asserted by spec to change neither
    # Board.count nor Image.count.
    def preview
      @form = submitted_form
      @problems = validation_problems(@form)
      return render(:new, status: :unprocessable_entity) if @problems.any?

      @preview = Boards::AdminBuilder::ArtPreview.new(
        pages: pages_for(@form),
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
        plan: {
          "tiles" => Boards::AdminBuilder::Plan.stringify_tiles(@form[:tiles]),
          "children" => @form[:children].map do |child|
            {
              "key" => child[:key],
              "name" => child[:name],
              "columns" => child[:columns].presence&.to_i,
              "rows" => child[:rows].presence&.to_i,
              "tiles" => Boards::AdminBuilder::Plan.stringify_tiles(child[:tiles]),
            }.compact
          end,
        },
      )
      BuildAdminBoardJob.perform_async(build.id)

      redirect_to admin_dashboard_board_build_path(build),
                  notice: "Building “#{build.name}” — it lands unpublished for review."
    end

    def show
      @board = builder_board_for(@build)
      @set_boards = @build.set_boards
      @tiles_by_board = @set_boards.index_with { |board| board.board_images.includes(:image).order(:position) }
      @missing_art_count = @set_boards.sum { |board| missing_art_count(board) }
    end

    # Publishing is a set-wide operation. `Board#viewable_by?` gates each board
    # on its OWN published flag, so publishing only the root leaves every folder
    # tile 404ing for a public visitor — the set has to move as a unit.
    def publish
      board = builder_board_for(@build)
      return redirect_to(admin_dashboard_board_build_path(@build), alert: "No board to publish yet.") if board.nil?

      if board.board_images.empty?
        return redirect_to admin_dashboard_board_build_path(@build),
                           alert: "This board has no tiles — refusing to publish an empty board."
      end

      set = @build.set_boards
      empty = set.reject { |page| page.board_images.any? }
      if empty.any?
        return redirect_to admin_dashboard_board_build_path(@build),
                           alert: "#{empty.map(&:name).to_sentence} has no tiles — " \
                                  "refusing to publish a set with an empty page."
      end

      set.each { |page| page.update!(published: true) }
      redirect_to admin_dashboard_board_build_path(@build), notice: publish_notice(board, set, "now public")
    end

    def unpublish
      board = builder_board_for(@build)
      return redirect_to(admin_dashboard_board_build_path(@build), alert: "No board to unpublish.") if board.nil?

      set = @build.set_boards
      set.each { |page| page.update!(published: false) }
      redirect_to admin_dashboard_board_build_path(@build), notice: publish_notice(board, set, "no longer public")
    end

    def destroy
      board = builder_board_for(@build)
      if board&.published?
        return redirect_to admin_dashboard_board_builds_path,
                           alert: "“#{board.name}” is published — unpublish it before deleting."
      end

      name = @build.name
      set = @build.set_boards
      # The build row first: admin_board_builds.board_id carries a foreign key,
      # so destroying the board while the build still points at it violates it.
      @build.destroy
      # Children before the root: a child's back-link is a predictive_board_id
      # onto the root, and destroying the root first leaves those pointing at
      # nothing for as long as the loop runs.
      set.reverse_each(&:destroy)
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

    # The whole suggestion, so a partially-filled form only has the blank half
    # replaced — an explicitly typed topic or audience is never overwritten.
    def suggest_context(form)
      context = Boards::AdminBuilder::ContextSuggester.new(name: form[:name], words: form[:words]).call

      {
        topic: form[:topic].presence || context[:topic],
        audience: form[:audience].presence || context[:audience],
      }
    end

    # Same, but a failure here is not fatal: drafting can still go ahead if the
    # admin typed a topic themselves, and `draft_problems` reports it if not.
    def suggested_context(form)
      return {} if form[:name].blank? && form[:words].strip.blank?

      suggest_context(form)
    end

    # Drafting needs something to draft about and a grid to size the list. The
    # topic is inferred from the board first, so this only fires when there was
    # nothing to infer it from.
    def draft_problems(form)
      problems = []
      problems << "Give the board a name or a topic to draft from." if form[:topic].blank?

      columns = form[:columns].to_i
      rows = form[:rows].to_i
      problems << "Columns must be between 1 and #{MAX_COLUMNS}." unless columns.between?(1, MAX_COLUMNS)
      problems << "Rows must be between 1 and #{MAX_ROWS}." unless rows.between?(1, MAX_ROWS)
      problems
    end

    def tiles_to_words(tiles)
      tiles.map { |tile| "#{tile[:label]} | #{tile[:part_of_speech]}" }.join("\n")
    end

    # The drafter can come back short (near-duplicates get dropped), which is
    # survivable because this only fills the textarea — but say so rather than
    # letting the admin discover it at preview.
    def draft_notice(tiles, form)
      wanted = form[:columns].to_i * form[:rows].to_i
      return "Drafted #{tiles.size} words. Edit them, then preview the art." if tiles.size == wanted

      "Drafted #{tiles.size} of #{wanted} words — add #{wanted - tiles.size} more before previewing."
    end

    def blank_form
      {
        name: "",
        topic: "",
        audience: "",
        voice: DEFAULT_VOICE,
        columns: DEFAULT_COLUMNS.to_s,
        rows: DEFAULT_ROWS.to_s,
        words: "",
        tiles: [],
        children: [],
        commercial_safe_only: true,
        allow_partial_row: false,
        allow_mixed_grids: false,
      }
    end

    def blank_child
      { key: "", name: "", columns: "", rows: "", words: "", tiles: [] }
    end

    # Keeps the raw submitted strings so a failed submit re-renders exactly what
    # the admin typed. Reads raw params rather than strong params, matching
    # Admin::VideoBoardsController.
    def submitted_form
      words = params[:words].to_s

      {
        name: params[:name].to_s.strip,
        topic: params[:topic].to_s.strip,
        audience: params[:audience].to_s.strip,
        voice: params[:voice].to_s.strip.presence || DEFAULT_VOICE,
        columns: params[:columns].to_s.strip,
        rows: params[:rows].to_s.strip,
        words: words,
        tiles: parse_tiles(words),
        children: submitted_children,
        commercial_safe_only: checked?(params[:commercial_safe_only]),
        allow_partial_row: checked?(params[:allow_partial_row]),
        allow_mixed_grids: checked?(params[:allow_mixed_grids]),
      }
    end

    # Child pages arrive as an indexed hash, the same shape
    # Admin::VideoBoardsController reads its video rows from. A wholly blank
    # block is dropped so an unused "add a page" click isn't a validation error.
    def submitted_children
      params.fetch(:children, {}).values.filter_map do |child|
        words = child[:words].to_s
        page = {
          key: child[:key].to_s.strip.downcase,
          name: child[:name].to_s.strip,
          columns: child[:columns].to_s.strip,
          rows: child[:rows].to_s.strip,
          words: words,
          tiles: parse_tiles(words),
        }
        next if page[:key].blank? && page[:name].blank? && words.strip.blank?

        page
      end
    end

    def checked?(value)
      ActiveModel::Type::Boolean.new.cast(value) || false
    end

    # One tile per line: `word`, `word | part_of_speech`, or
    # `word | part_of_speech | tile text`. A textarea rather than N inputs
    # because a dense board is 24-84 words and pasting a list is the job.
    #
    # A field beginning with `>` names the page the tile opens, wherever it
    # appears in the line — so `Food | noun | >food` doesn't force an empty
    # tile-text field just to reach a fourth position.
    def parse_tiles(words)
      words.to_s.split("\n").filter_map do |line|
        line = line.strip
        next if line.blank?

        label, *rest = line.split("|").map { |part| part.to_s.strip }
        links_to = rest.find { |field| field.start_with?(LINK_TOKEN) }
        part_of_speech, display_label = rest - [links_to].compact

        {
          label: label.to_s,
          part_of_speech: part_of_speech.presence || "default",
          display_label: display_label.presence,
          links_to: links_to&.delete_prefix(LINK_TOKEN)&.strip&.downcase.presence,
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
      problems.concat(child_grid_range_problems(form))
      return problems if problems.any?

      problems + Boards::AdminBuilder::PlanValidator.new(
        pages: pages_for(form),
        allow_partial_row: form[:allow_partial_row],
        allow_mixed_grids: form[:allow_mixed_grids],
      ).call
    end

    # Range-checked before the plan is assembled, because Plan#child_page reads
    # an out-of-range override straight into a grid the validator would then
    # describe rather than reject.
    def child_grid_range_problems(form)
      form[:children].flat_map do |child|
        label = child[:name].presence || child[:key].presence || "A page"
        problems = []
        if child[:columns].present? && !child[:columns].to_i.between?(1, MAX_COLUMNS)
          problems << "#{label}: columns must be between 1 and #{MAX_COLUMNS}."
        end
        if child[:rows].present? && !child[:rows].to_i.between?(1, MAX_ROWS)
          problems << "#{label}: rows must be between 1 and #{MAX_ROWS}."
        end
        problems
      end
    end

    def pages_for(form)
      Boards::AdminBuilder::Plan.pages(
        root: {
          name: form[:name],
          columns: form[:columns].to_i,
          rows: form[:rows].to_i,
          tiles: form[:tiles],
        },
        children: form[:children],
      )
    end

    def publish_notice(root, set, state)
      return "“#{root.name}” is #{state}." if set.size <= 1

      "“#{root.name}” and its #{set.size - 1} #{"page".pluralize(set.size - 1)} are #{state}."
    end
  end
end
