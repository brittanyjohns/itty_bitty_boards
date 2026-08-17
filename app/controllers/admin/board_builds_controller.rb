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
  #   3. Boards are owned by User::DEFAULT_ADMIN_ID and created published but
  #      NOT predefined — public at /pb/<slug> and listed on the printables
  #      page, without being dropped into the public catalogue. Every member
  #      action is scoped through AdminBoardBuild.builder_boards so it can never
  #      reach a board this page didn't create; unpublish is the way back.
  class BoardBuildsController < Admin::ApplicationController
    MAX_COLUMNS = 12
    # 12x12, the old grid ceiling expressed as tiles.
    MAX_TILES = 144
    DEFAULT_COLUMNS = 6
    DEFAULT_TILES = 24
    DEFAULT_PAGE_COUNT = 0
    DEFAULT_VOICE = "polly:kevin".freeze

    before_action :require_seed_admin!

    helper_method :existing_board_matches
    before_action :set_build, only: %i[show update destroy publish unpublish duplicate regenerate_art finish]

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
      # Neither a name nor a topic is a prerequisite for drafting: whichever is
      # missing is inferred from whatever else the form has, so a draft can
      # start from a name, a topic, or a pasted word list alone.
      #
      # Deliberately NOT gated on a blank audience. Audience is optional to the
      # drafter, so it isn't worth a round trip of its own — but name and topic
      # both are (preview and build require a name; topic steers every art
      # prompt), and the one call answers all three anyway.
      @form = @form.merge(suggested_context(@form)) if @form[:topic].blank? || @form[:name].blank?
      @problems = draft_problems(@form)
      return render(:new, status: :unprocessable_entity) if @problems.any?

      # Drafting replaces the root outright, so every page is about to need a
      # folder tile written back in. Asking for that many fewer words lands on
      # the tile count exactly, instead of drafting a full board and then having
      # its tail displaced to make room.
      reserved = Boards::AdminBuilder::FolderTiles.reserved_count(children: @form[:children])
      tiles = Boards::AdminBuilder::WordListDrafter.new(
        topic: @form[:topic],
        tile_count: [@form[:tile_count].to_i - reserved, 1].max,
        audience: @form[:audience],
      ).call

      @form = with_folder_tiles(@form.merge(words: tiles_to_words(tiles), tiles: tiles))
      flash.now[:notice] = draft_notice(@form[:tiles], @form)
      render :new
    rescue Boards::AdminBuilder::WordListDrafter::GenerationError => e
      @problems = ["Couldn't draft a word list: #{e.message}"]
      render :new, status: :unprocessable_entity
    rescue Boards::AdminBuilder::ContextSuggester::GenerationError => e
      @problems = ["Couldn't work out the topic: #{e.message}"]
      render :new, status: :unprocessable_entity
    end

    # Additive form of `draft`: tops up whatever the admin already typed with
    # only the words missing to reach tile_count, instead of replacing it.
    def add_words
      @form = submitted_form
      @form = @form.merge(suggested_context(@form)) if @form[:topic].blank? || @form[:name].blank?
      @problems = draft_problems(@form)

      existing = @form[:tiles]
      missing = @form[:tile_count].to_i - existing.size
      if @problems.empty? && missing <= 0
        @problems << "Already have #{existing.size} of #{@form[:tile_count]} words — " \
                      "raise Tiles or remove some before adding more."
      end
      return render(:new, status: :unprocessable_entity) if @problems.any?

      new_tiles = Boards::AdminBuilder::WordListDrafter.new(
        topic: @form[:topic],
        tile_count: missing,
        audience: @form[:audience],
        existing_labels: existing.map { |tile| tile[:label] },
      ).call

      all_tiles = existing + new_tiles
      @form = with_folder_tiles(@form.merge(words: tiles_to_words(all_tiles), tiles: all_tiles))
      flash.now[:notice] = add_words_notice(new_tiles, missing, @form)
      render :new
    rescue Boards::AdminBuilder::WordListDrafter::GenerationError => e
      @problems = ["Couldn't draft more words: #{e.message}"]
      render :new, status: :unprocessable_entity
    rescue Boards::AdminBuilder::ContextSuggester::GenerationError => e
      @problems = ["Couldn't work out the topic: #{e.message}"]
      render :new, status: :unprocessable_entity
    end

    # Optional step zero, the multi-page form of `draft`. Drafts the whole set
    # — root word list with its folder tiles already linked, plus each page —
    # into the form and stops there. Nothing is previewed or built from it.
    #
    # Page keys and names already on the form are authored input: they are
    # passed through and used verbatim, and the AI only names the pages that are
    # still blank. Word lists are the part this replaces.
    def draft_set
      @form = submitted_form
      @form = @form.merge(suggested_context(@form)) if @form[:topic].blank? || @form[:name].blank?
      @problems = draft_problems(@form)
      return render(:new, status: :unprocessable_entity) if @problems.any?

      set = Boards::AdminBuilder::SetDrafter.new(
        topic: @form[:topic],
        columns: @form[:columns].to_i,
        tile_count: @form[:tile_count].to_i,
        page_count: @form[:page_count].to_i,
        audience: @form[:audience],
        pages: named_pages(@form),
      ).call

      # The prompt asks for a folder tile per page, but a draft that came back
      # without one would otherwise build an unreachable page.
      @form = with_folder_tiles(@form.merge(
        words: tiles_to_words(set[:root_tiles]),
        tiles: set[:root_tiles],
        children: children_form_from(set[:children]),
        # Naming more pages than the count asked for raises the count rather
        # than dropping the names, so the select has to follow.
        page_count: (set[:page_count] || @form[:page_count]).to_s,
      ))
      flash.now[:notice] = draft_set_notice(set, @form)
      render :new
    rescue Boards::AdminBuilder::SetDrafter::GenerationError => e
      @problems = ["Couldn't draft the set: #{e.message}"]
      render :new, status: :unprocessable_entity
    rescue Boards::AdminBuilder::ContextSuggester::GenerationError => e
      @problems = ["Couldn't work out the topic: #{e.message}"]
      render :new, status: :unprocessable_entity
    end

    # Per-page form of `draft`: fills ONE child page's word list from that
    # page's title, leaving the root and every other page exactly as typed.
    # `draft_set` is the only other way to get words onto a page and it replaces
    # the whole set, so editing one page of a set previously meant re-drafting
    # (and re-editing) all of it.
    #
    # Also the way past SetDrafter::MAX_PAGES: one page per call keeps the
    # per-page tile count accurate where a single long response drifts.
    def draft_page
      @form = submitted_form
      index = params[:page_index].to_i
      child = @form[:children][index]

      @problems = draft_page_problems(@form, child)
      return render(:new, status: :unprocessable_entity) if @problems.any?

      tile_count = child[:tile_count].presence&.to_i || @form[:tile_count].to_i
      tiles = Boards::AdminBuilder::PageDrafter.new(
        page_name: child[:name],
        page_key: child[:key],
        tile_count: tile_count,
        # The page title is the subject; a blank board topic is context this
        # page can do without, so no ContextSuggester round trip here.
        topic: @form[:topic],
        audience: @form[:audience],
      ).call

      @form[:children][index] = child.merge(words: tiles_to_words(tiles), tiles: tiles)
      @form = with_folder_tiles(@form)
      flash.now[:notice] = draft_page_notice(tiles, child, tile_count)
      render :new
    rescue Boards::AdminBuilder::PageDrafter::GenerationError => e
      @problems = ["Couldn't draft that page: #{e.message}"]
      render :new, status: :unprocessable_entity
    end

    # Names the pages and nothing else — no words, no grids. The set drafter
    # then honours those names, so this is the "decide the shape first" half of
    # `draft_set`: titles are the cheapest thing to read and re-read, and a set
    # drafted under the wrong page names is thrown away wholesale.
    def suggest_pages
      @form = submitted_form
      @form = @form.merge(suggested_context(@form)) if @form[:topic].blank?
      @problems = suggest_pages_problems(@form)
      return render(:new, status: :unprocessable_entity) if @problems.any?

      pages = Boards::AdminBuilder::PageNamesSuggester.new(
        topic: @form[:topic],
        name: @form[:name],
        audience: @form[:audience],
        count: suggested_page_count(@form),
        existing: named_pages(@form),
      ).call

      children = children_named_from(@form[:children], pages)
      # Naming a page is what makes it a page, so the folder tile that opens it
      # is written now rather than a round trip later.
      @form = with_folder_tiles(@form.merge(children: children, page_count: page_count_for(children, @form)))
      flash.now[:notice] = suggest_pages_notice(pages)
      render :new
    rescue Boards::AdminBuilder::PageNamesSuggester::GenerationError => e
      @problems = ["Couldn't suggest page names: #{e.message}"]
      render :new, status: :unprocessable_entity
    rescue Boards::AdminBuilder::ContextSuggester::GenerationError => e
      @problems = ["Couldn't work out the topic: #{e.message}"]
      render :new, status: :unprocessable_entity
    end

    # Fills in topic and audience on their own, so they can be read and edited
    # before a whole word list is drafted from them.
    def suggest
      @form = submitted_form
      if nothing_to_infer_from?(@form)
        @problems = ["Give the board a name, a topic, or some words to work from."]
        return render(:new, status: :unprocessable_entity)
      end

      @form = @form.merge(suggest_context(@form))
      flash.now[:notice] = "Filled in what was blank — edit it, or draft a word list."
      render :new
    rescue Boards::AdminBuilder::ContextSuggester::GenerationError => e
      @problems = ["Couldn't suggest a topic: #{e.message}"]
      render :new, status: :unprocessable_entity
    end

    # Fills the public description and catalogue tags from whatever the form
    # currently holds. Separate from drafting on purpose — the word list is
    # usually edited after a draft, and a description written from the pre-edit
    # list would be stale.
    def describe_board
      @form = submitted_form
      pages = pages_for(@form)

      metadata = Boards::AdminBuilder::MetadataSuggester.new(
        name: @form[:name],
        topic: @form[:topic],
        audience: @form[:audience],
        labels: Boards::AdminBuilder::Plan.labels(pages),
        page_names: pages.drop(1).map { |page| page[:name] },
      ).call

      @form = @form.merge(description: metadata[:description], tags: metadata[:tags].join(", "))
      flash.now[:notice] = "Suggested a description and tags — edit them before you build."
      render :new
    rescue Boards::AdminBuilder::MetadataSuggester::GenerationError => e
      @problems = ["Couldn't suggest a description: #{e.message}"]
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
      @marked = marked_labels(@form)
      @picked_docs = picked_docs(@form)
      @name_matches = duplicate_name_matches(@form[:name])

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
        tile_count: @form[:tile_count].to_i,
        commercial_safe_only: @form[:commercial_safe_only],
        description: @form[:description].presence,
        tags: submitted_tags(tags: @form[:tags]),
        audience: @form[:audience].presence,
        plan: {
          "tiles" => Boards::AdminBuilder::Plan.stringify_tiles(@form[:tiles]),
          "children" => @form[:children].map do |child|
            linked = child[:existing_board_id].presence&.to_i
            {
              "key" => child[:key],
              "name" => child[:name],
              "columns" => child[:columns].presence&.to_i,
              "tile_count" => child[:tile_count].presence&.to_i,
              # A linked page stores no word list. Plan.child_page blanks the
              # tiles too, but keeping them out of the stored plan means
              # re-opening the build through `duplicate` doesn't resurrect a
              # word list the page never used.
              "tiles" => linked ? [] : Boards::AdminBuilder::Plan.stringify_tiles(child[:tiles]),
              "existing_board_id" => linked,
            }.compact
          end,
          # Marks made on the review screen. Re-filtered against the plan here
          # rather than trusted from the resubmit, and stored normalized so
          # Boards::AdminBuilder::Build can look each one up in `resolved`.
          "regenerate" => marked_labels(@form),
          # Per-label doc picks made on the review screen. A picked doc and an
          # AI regeneration are the same decision made two ways, so a pick wins
          # and the mark is dropped — otherwise the build would pin the chosen
          # picture and then immediately generate over it.
          "display_docs" => picked_docs(@form),
        },
      )
      BuildAdminBoardJob.perform_async(build.id)

      redirect_to admin_dashboard_board_build_path(build),
                  notice: "Building “#{build.name}” — it lands published, ready to print. " \
                          "Check the art and unpublish it if anything's wrong."
    end

    def show
      @board = builder_board_for(@build)
      @set_boards = @build.set_boards
      @tiles_by_board = @set_boards.index_with { |board| board.board_images.includes(:image).order(:position) }
      @missing_art_count = @set_boards.sum { |board| missing_art_count(board) }
    end

    # Loads a past build back into the authoring form. Writes nothing — it is
    # `new` with the fields filled in, so a revision is a tweak instead of a
    # re-type. The name is copied verbatim; `preview` warns about the
    # collision rather than forcing an edit up front.
    def duplicate
      # Runs the folder-tile pass too, so re-opening a set built before this
      # existed repairs its missing doors instead of reproducing them.
      @form = with_folder_tiles(form_from_build(@build))
      flash.now[:notice] = "Loaded “#{@build.name}” into the form. Nothing is written until you build."
      render :new
    end

    # The only mutable part of a finished build. The word list stays frozen —
    # fixing words is still delete-and-rebuild — but a description or a tag is
    # exactly the kind of thing that is wrong once and cheap to correct.
    def update
      description = params[:description].to_s.strip.presence
      tags = submitted_tags(tags: params[:tags])

      @build.update!(description: description, tags: tags)
      builder_board_for(@build)&.update!(description: description, tags: tags)

      redirect_to admin_dashboard_board_build_path(@build), notice: "Updated the description and tags."
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

    # Art generation can fail or be missed; the build page already counts what
    # has no picture, so give it a way to act on the count. Recomputed from the
    # boards rather than replayed from art_report, so a tile whose art arrived
    # since isn't generated twice.
    def regenerate_art
      set = @build.set_boards
      root = builder_board_for(@build)
      image_ids = set.flat_map { |page| queueable_image_ids(page) }.uniq

      if root.nil? || image_ids.empty?
        return redirect_to admin_dashboard_board_build_path(@build),
                           notice: "Every tile already has a picture, or art is still generating for the rest — nothing new to queue."
      end

      queued = Boards::AdminBuilder::ArtQueue.call(board: root, image_ids: image_ids, topic: @build.topic)
      redirect_to admin_dashboard_board_build_path(@build),
                  notice: "Queued art for #{queued} #{"tile".pluralize(queued)}."
    end

    # Re-run the tail of a build whose set is already written: the art report
    # and the art queueing that a failure at or after the commit skipped.
    # Re-queues the same job, which never rebuilds a set it already owns — so
    # this is the recovery path for a build stuck showing "failed" (or a
    # warning) over boards that are perfectly fine.
    def finish
      unless @build.needs_finishing?
        return redirect_to admin_dashboard_board_build_path(@build),
                           notice: "Nothing left to finish — this build is complete."
      end

      BuildAdminBoardJob.perform_async(@build.id)
      redirect_to admin_dashboard_board_build_path(@build),
                  notice: "Finishing the build — reload in a moment."
    end

    def destroy
      board = builder_board_for(@build)
      if board&.published?
        return redirect_to admin_dashboard_board_builds_path,
                           alert: "“#{board.name}” is published — unpublish it before deleting."
      end

      name = @build.name
      set = @build.set_boards

      # The whole set, not just the root: any page of a built tree can be the
      # page a printable was sold from, and `set.reverse_each(&:destroy)` would
      # otherwise hit the model guard mid-loop with the build row already gone.
      blocked = Boards::MarketplaceProtection.protected_board_ids(set.map(&:id))
      if blocked.any?
        names = Board.where(id: blocked.to_a).pluck(:name).to_sentence
        return redirect_to admin_dashboard_board_builds_path,
                           alert: "#{names} #{blocked.size == 1 ? "is" : "are"} sold as a printable — release protection on the printable before deleting this build."
      end
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

    # Advisory only. Two boards with one name is sometimes right; shipping it
    # by accident is what's worth catching. Both scopes are searched because a
    # board built here last week and still awaiting review isn't public yet.
    def duplicate_name_matches(name)
      return Board.none if name.blank?

      Board.where(id: Board.public_boards.select(:id))
           .or(Board.where(id: AdminBoardBuild.builder_boards.select(:id)))
           .where("lower(boards.name) = ?", name.strip.downcase)
           .limit(5)
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

    def art_less_image_ids(board)
      Image.where(id: board.board_images.select(:image_id)).where.missing(:docs).pluck(:id)
    end

    # regenerate_art must not re-queue an image that's already mid-flight from
    # a prior GenerateImagesJob — art_less_image_ids alone can't tell "never
    # queued" from "queued and still generating" (both have no docs yet).
    # missing_art_count keeps using art_less_image_ids unchanged: it's a
    # display count of "still no picture," and in-flight images belong in it.
    def queueable_image_ids(board)
      # `where.not(status: "generating")` would also exclude NULL-status rows
      # (SQL's `!=` against NULL is unknown, not true) — most art-less images
      # have never had a status set at all, so that would drop them too.
      # IS DISTINCT FROM is NULL-safe: NULL is kept, only "generating" is cut.
      Image.where(id: art_less_image_ids(board)).where("status IS DISTINCT FROM ?", "generating").pluck(:id)
    end

    def missing_art_count(board)
      art_less_image_ids(board).size
    end

    def voice_values
      @voice_values ||= VoiceService::VOICES.map { |voice| voice[:value] }
    end

    def nothing_to_infer_from?(form)
      form[:name].blank? && form[:topic].blank? && form[:words].strip.blank?
    end

    # Only the blanks are filled — anything the admin typed is never
    # overwritten, including the name.
    def suggest_context(form)
      context = Boards::AdminBuilder::ContextSuggester.new(
        name: form[:name], topic: form[:topic], words: form[:words],
      ).call

      {
        name: form[:name].presence || context[:name],
        topic: form[:topic].presence || context[:topic],
        audience: form[:audience].presence || context[:audience],
      }
    end

    # Same, but skipped rather than raised when there is nothing to work from —
    # `draft_problems` reports that more usefully than a generation error would.
    def suggested_context(form)
      return {} if nothing_to_infer_from?(form)

      suggest_context(form)
    end

    # Drafting needs something to draft about and a size for the list. The
    # topic is inferred from the board first, so this only fires when there was
    # nothing to infer it from.
    def draft_problems(form)
      problems = []
      problems << "Give the board a name or a topic to draft from." if form[:topic].blank?

      columns = form[:columns].to_i
      tiles = form[:tile_count].to_i
      problems << "Columns must be between 1 and #{MAX_COLUMNS}." unless columns.between?(1, MAX_COLUMNS)
      problems << "Tiles must be between 1 and #{MAX_TILES}." unless tiles.between?(1, MAX_TILES)
      problems
    end

    # A page title is the whole input, so it's the one thing that can't be
    # inferred. The tile count is the page's own override when it has one and
    # the root's otherwise, matching what the page will actually be built at.
    def draft_page_problems(form, child)
      return ["That page is no longer on the form — add it again before drafting."] if child.nil?

      problems = []
      if child[:name].blank? && child[:key].blank?
        problems << "Give the page a name to draft from."
      end

      tiles = child[:tile_count].presence&.to_i || form[:tile_count].to_i
      problems << "Tiles must be between 1 and #{MAX_TILES}." unless tiles.between?(1, MAX_TILES)
      problems
    end

    # Same shortfall handling as draft_notice — the drafter can come back short
    # when near-duplicates get dropped, and the admin should hear that here
    # rather than discover it at preview.
    def draft_page_notice(tiles, child, wanted)
      page = child[:name].presence || child[:key]
      if tiles.size == wanted
        return "Drafted #{tiles.size} words for “#{page}”. Edit them, then preview the art."
      end

      "Drafted #{tiles.size} of #{wanted} words for “#{page}” — " \
        "add #{wanted - tiles.size} more before previewing."
    end

    # The pages the admin has already named, in form order. A block with only a
    # key or only a name still counts — the suggester and the set drafter both
    # fill the missing half rather than treating it as unnamed.
    def named_pages(form)
      form[:children].filter_map do |child|
        next if child[:key].blank? && child[:name].blank?

        { key: child[:key], name: child[:name] }
      end
    end

    # Never fewer pages than are already on the form: a suggestion that dropped
    # a block the admin added would take its word list with it.
    def suggested_page_count(form)
      [form[:page_count].to_i, form[:children].size, 1].max
        .clamp(1, Boards::AdminBuilder::SetDrafter::MAX_PAGES)
    end

    def suggest_pages_problems(form)
      return ["Give the board a name or a topic to suggest pages from."] if form[:topic].blank?

      []
    end

    # Suggested names fill the unnamed blocks where they sit — never by
    # position in the suggestion, which would move a name onto a block that
    # already holds someone else's word list. Whatever is left over becomes new
    # blank blocks at the end.
    def children_named_from(children, pages)
      taken = named_pages({ children: children })
              .map { |page| Boards::AdminBuilder::Keys.normalize(page[:key].presence || page[:name]) }
              .to_set
      extras = pages.reject { |page| taken.include?(page[:key]) }

      filled = children.map do |child|
        next child if child[:key].present? || child[:name].present?

        page = extras.shift
        page ? child.merge(key: page[:key], name: page[:name]) : child
      end

      filled + extras.map { |page| blank_child.merge(key: page[:key], name: page[:name]) }
    end

    # The select only offers 0..MAX_PAGES, so a form carrying more blocks than
    # that keeps whatever it had rather than being shown a count it can't hold.
    def page_count_for(children, form)
      return form[:page_count] if children.size > Boards::AdminBuilder::SetDrafter::MAX_PAGES

      children.size.to_s
    end

    def suggest_pages_notice(pages)
      "Suggested #{pages.size} #{"page".pluralize(pages.size)} — " \
        "edit the names, then draft the set to fill them with words."
    end

    def tiles_to_words(tiles)
      Boards::AdminBuilder::WordList.render(tiles)
    end

    # Children arrive as tile hashes; the form wants a rendered textarea per
    # page. Grids are deliberately left blank so each page inherits the root's.
    def children_form_from(children)
      Array(children).map do |child|
        {
          key: child[:key].to_s,
          name: child[:name].to_s,
          columns: "",
          tile_count: "",
          words: tiles_to_words(child[:tiles]),
          tiles: child[:tiles],
        }
      end
    end

    def draft_set_notice(set, form)
      wanted_tiles = form[:tile_count].to_i
      # What was attempted, not what the select said: pages the admin named
      # above the count raise it rather than being dropped.
      wanted_pages = (set[:page_count] || form[:page_count]).to_i
      pages = set[:children].size
      short_boards = ([set[:root_tiles]] + set[:children].map { |child| child[:tiles] })
                     .count { |tiles| tiles.size != wanted_tiles }

      base = "Drafted the main board and #{pages} #{"page".pluralize(pages)}."
      return "#{base} Edit them, then preview the art." if short_boards.zero? && pages == wanted_pages

      warnings = []
      if pages < wanted_pages
        missing = wanted_pages - pages
        warnings << "the AI came back #{missing} #{"page".pluralize(missing)} short of the #{wanted_pages} " \
                     "you asked for"
      end
      if short_boards.positive?
        warnings << "#{short_boards} #{"board".pluralize(short_boards)} didn't come back with exactly " \
                     "#{wanted_tiles} words"
      end

      "#{base} #{warnings.join("; ").capitalize} — check the counts before previewing."
    end

    # The drafter can come back short (near-duplicates get dropped), which is
    # survivable because this only fills the textarea — but say so rather than
    # letting the admin discover it at preview.
    def draft_notice(tiles, form)
      wanted = form[:tile_count].to_i
      return "Drafted #{tiles.size} words. Edit them, then preview the art." if tiles.size == wanted

      "Drafted #{tiles.size} of #{wanted} words — add #{wanted - tiles.size} more before previewing."
    end

    # Same shortfall handling as draft_notice, but against the top-up ask
    # (`wanted_new`) rather than the board's total tile_count.
    def add_words_notice(new_tiles, wanted_new, form)
      total = form[:tiles].size
      target = form[:tile_count].to_i
      if new_tiles.size == wanted_new
        return "Added #{new_tiles.size} #{"word".pluralize(new_tiles.size)} " \
               "(#{total} of #{target} so far). Edit them, then preview the art."
      end

      "Added #{new_tiles.size} of #{wanted_new} more words (#{total} of #{target} so far) — " \
        "add #{target - total} more before previewing."
    end

    def blank_form
      {
        name: "",
        topic: "",
        audience: "",
        description: "",
        tags: "",
        voice: DEFAULT_VOICE,
        columns: DEFAULT_COLUMNS.to_s,
        tile_count: DEFAULT_TILES.to_s,
        page_count: DEFAULT_PAGE_COUNT.to_s,
        words: "",
        tiles: [],
        children: [],
        commercial_safe_only: true,
        allow_partial_row: false,
        allow_mixed_grids: false,
        regenerate: [],
        display_docs: {},
      }
    end

    def blank_child
      { key: "", name: "", columns: "", tile_count: "", words: "", tiles: [], existing_board_id: "" }
    end

    def form_from_build(build)
      pages = build.pages
      root = pages.first

      blank_form.merge(
        name: build.name.to_s,
        topic: build.topic.to_s,
        audience: build.audience.to_s,
        description: build.description.to_s,
        tags: Array(build.tags).join(", "),
        voice: build.voice.presence || DEFAULT_VOICE,
        columns: build.columns_count.to_s,
        tile_count: build.tile_count.to_s,
        words: tiles_to_words(root[:tiles]),
        tiles: root[:tiles],
        # Grids are left blank so every page keeps inheriting the root's, which
        # is what the stored plan meant when it omitted them.
        children: pages.drop(1).map do |page|
          {
            key: page[:key], name: page[:name], columns: "", tile_count: "",
            words: tiles_to_words(page[:tiles]), tiles: page[:tiles],
            existing_board_id: page[:existing_board_id].to_s,
          }
        end,
        commercial_safe_only: build.commercial_safe_only,
      )
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
        description: params[:description].to_s.strip,
        tags: params[:tags].to_s,
        voice: params[:voice].to_s.strip.presence || DEFAULT_VOICE,
        columns: params[:columns].to_s.strip,
        tile_count: params[:tile_count].to_s.strip,
        page_count: params[:page_count].to_s.strip,
        words: words,
        tiles: parse_tiles(words),
        children: submitted_children,
        commercial_safe_only: checked?(params[:commercial_safe_only]),
        allow_partial_row: checked?(params[:allow_partial_row]),
        allow_mixed_grids: checked?(params[:allow_mixed_grids]),
        regenerate: submitted_regenerate,
        display_docs: submitted_display_docs,
      }.then { |form| with_folder_tiles(form) }
    end

    # Docs the admin pinned on the review screen, as label => doc id. Keyed the
    # same way marks are so a pick survives whatever casing the word was
    # authored in. A blank value is "use the library's pick" and drops out here.
    def submitted_display_docs
      submitted = params[:display_docs]
      # A hand-edited `display_docs=whatever` arrives as a String, not a hash.
      return {} unless submitted.respond_to?(:to_unsafe_h)

      submitted.to_unsafe_h.filter_map do |label, doc_id|
        key = Boards::ImageResolver.normalize(label)
        next if key.blank? || doc_id.to_i <= 0

        [key, doc_id.to_i]
      end.first(MAX_TILES).to_h
    end

    # Labels the admin ticked "regenerate with AI" on the review screen.
    # Normalized through the resolver's own key so a mark survives whatever
    # casing the word was authored in, and matches what Build looks up.
    def submitted_regenerate
      Array(params[:regenerate])
        .map { |label| Boards::ImageResolver.normalize(label) }
        .reject(&:blank?)
        .uniq
        .first(MAX_TILES)
    end

    # The round trip is not trusted. A mark only means anything if the word is
    # still in the plan — the admin may have edited the list after ticking it,
    # and a hand-edited field must not be able to name an arbitrary label.
    def marked_labels(form)
      (form[:regenerate] & planned_labels(form)) - picked_docs(form).keys
    end

    # Label => doc id for tiles the admin pinned a specific picture to. Filtered
    # the same way marks are — a pick only means anything if the word is still
    # in the plan — and the doc id is checked against the library rather than
    # trusted, so a hand-edited field can't pin a private user upload onto a
    # public board.
    def picked_docs(form)
      picks = form[:display_docs].slice(*planned_labels(form))
      return {} if picks.empty?

      allowed = Doc.image_docs
                   .where(id: picks.values, user_id: [nil, User::DEFAULT_ADMIN_ID])
                   .pluck(:id)
                   .to_set
      picks.select { |_label, doc_id| allowed.include?(doc_id) }
    end

    def planned_labels(form)
      Boards::AdminBuilder::Plan.labels(pages_for(form))
                                .map { |label| Boards::ImageResolver.normalize(label) }
    end

    # Writes a folder tile onto the main board for any page nothing opens, and
    # re-renders the root textarea so the admin sees the line that was added.
    #
    # Called on every round-trip — not once at submit — because every drafting
    # action replaces part of the form after `submitted_form` has run:
    # `draft` and `add_words` rewrite the root list (dropping the `>key` tokens
    # a set draft had put there), `draft_page` rewrites a page. Re-applying
    # after each of those is what makes a page reachable no matter which order
    # the buttons were pressed.
    #
    # `@auto_linked` is what the form and the preview report from; the last
    # call in a request wins, which is the state actually being rendered.
    def with_folder_tiles(form)
      @auto_linked = Boards::AdminBuilder::FolderTiles.link(
        root_tiles: form[:tiles],
        children: form[:children],
        tile_count: form[:tile_count].to_i,
      )
      return form unless @auto_linked.changed?

      form.merge(tiles: @auto_linked.tiles, words: tiles_to_words(@auto_linked.tiles))
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
          tile_count: child[:tile_count].to_s.strip,
          words: words,
          tiles: parse_tiles(words),
          # "" when the picker is on "create a new page", which is the default.
          # Validated as a real linkable board at build time, not here — this
          # only has to survive the round trip.
          existing_board_id: child[:existing_board_id].to_s.strip,
        }
        next if page[:key].blank? && page[:name].blank? && words.strip.blank?

        page
      end
    end

    # Published admin boards each page could point at instead of building a new
    # one, keyed by the downcased page name the block carries. Recomputed on
    # every round trip so renaming a page re-runs the lookup, in one query for
    # the whole form.
    #
    # A helper rather than an ivar set per action: eleven actions render this
    # form, and every one of them would have had to remember.
    def existing_board_matches(form)
      @existing_board_matches ||= Boards::AdminBuilder::ExistingBoards.matching(
        Array(form[:children]).map { |child| child[:name] },
        columns: form[:columns].to_i,
      )
    end

    def checked?(value)
      ActiveModel::Type::Boolean.new.cast(value) || false
    end

    # The form carries tags as one comma-separated string (the shape
    # Admin::VideoBoardsController uses). Normalized here so nothing downstream
    # has to care how they were typed. Takes the raw string rather than the
    # form hash because Task 7's `update` reads them straight off params.
    def submitted_tags(tags:)
      tags.to_s.split(",").map { |tag| Board.normalize_tag_value(tag) }.reject(&:blank?).uniq
    end

    def parse_tiles(words)
      Boards::AdminBuilder::WordList.parse(words)
    end

    def validation_problems(form)
      problems = []
      problems << "Give the board a name." if form[:name].blank?
      # VoiceService.normalize_voice passes through any string containing a
      # colon without validating it, so "polly:kevn" would save fine and only
      # fail later at audio synthesis. Constrain to the list.
      problems << "Pick a voice from the list." unless voice_values.include?(form[:voice])

      columns = form[:columns].to_i
      tiles = form[:tile_count].to_i
      problems << "Columns must be between 1 and #{MAX_COLUMNS}." unless columns.between?(1, MAX_COLUMNS)
      problems << "Tiles must be between 1 and #{MAX_TILES}." unless tiles.between?(1, MAX_TILES)
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
        if child[:tile_count].present? && !child[:tile_count].to_i.between?(1, MAX_TILES)
          problems << "#{label}: tiles must be between 1 and #{MAX_TILES}."
        end
        problems
      end
    end

    def pages_for(form)
      Boards::AdminBuilder::Plan.pages(
        root: {
          name: form[:name],
          columns: form[:columns].to_i,
          tile_count: form[:tile_count].to_i,
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
