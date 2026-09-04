class API::BoardsController < API::ApplicationController
  include BoardCreationLimit

  # add_image is the one board write a COMMUNICATOR may make: Quick add, where a
  # nonspeaking user drops a word onto a board on their own dashboard. It is
  # skipped from the user-only `authenticate_token!` and re-gated below by
  # `authenticate_signed_in!`, which accepts either credential.
  skip_before_action :authenticate_token!, only: %i[ index predictive_image_board show public_boards public_menu_boards common_boards pdf free_download_boards add_image ]

  # Declared BEFORE check_board_editable! so an unauthenticated caller is 401'd
  # and a communicator is scoped to their own boards before the plan gate runs.
  before_action :authenticate_signed_in!, only: %i[ add_image ]
  before_action :check_communicator_board_access!, only: %i[ add_image ]

  before_action :set_board, only: %i[ associate_image remove_image destroy associate_images print pdf assign_accounts show make_editable ]
  # Declared BEFORE check_board_editable!, which answers a different question:
  # User#board_editable? returns true for a board you don't own (it measures the
  # PLAN lock, not permission), so without this a signed-in user could add tiles
  # to anyone's board.
  before_action :check_board_view_edit_permissions, only: %i[update destroy add_word_pack]
  before_action :check_board_create_permissions, only: %i[ create clone clone_plan create_from_template import_obf ]
  before_action :check_board_editable!, only: %i[ save_layout rearrange_images update regenerate_images recategorize_images update_to_default_docs set_colors update_preset_display_image set_display_image format_with_ai add_image add_word_pack associate_image associate_images remove_image generate_preview_image ]
  # Declared AFTER check_board_editable! so the plan gate still answers first —
  # a read-only board is 403 board_locked whether or not it's also for sale.
  before_action :check_marketplace_edit_confirmed!, only: %i[ save_layout rearrange_images update regenerate_images recategorize_images update_to_default_docs set_colors update_preset_display_image set_display_image format_with_ai add_image add_word_pack associate_image associate_images remove_image ]

  def index
    limit_param = params[:limit].presence&.to_i
    page_param = params[:page].presence || 1
    page = page_param.to_i <= 0 ? 1 : page_param.to_i
    per_page = (limit_param || 30).clamp(1, 200)

    sort_field_param = params[:sort_field].presence || "created_at"
    sort_order_param = params[:sort_order].presence || "desc"

    allowed_sort_fields = %w[name created_at updated_at]
    allowed_sort_orders = %w[asc desc]

    sort_field = allowed_sort_fields.include?(sort_field_param) ? sort_field_param : "created_at"
    sort_order = allowed_sort_orders.include?(sort_order_param) ? sort_order_param : "desc"

    order_clause = { sort_field => sort_order.to_sym }
    if sort_field == "name"
      order_clause = Arel.sql("LOWER(name) #{sort_order.upcase}")
    end

    query = params[:query].to_s.strip.presence
    filter_param = params[:filter].to_s.strip.presence

    raw_tags = params[:tags]
    selected_tags = Array(raw_tags)
      .flat_map { |tag| tag.to_s.split(",") }
      .map { |tag| Board.normalize_tag_value(tag) }
      .reject(&:blank?)
      .uniq

    if filter_param.present? && !Board::SAFE_FILTERS.include?(filter_param)
      render json: { error: "Invalid filter" }, status: :unprocessable_content
      return
    end
    filter = filter_param

    public_tags = Board.public_boards_tags
    # ---------------------------
    # 1. GUEST (no current_user)
    # ---------------------------
    unless current_user
      static_scope = Board.public_boards
      static_scope = static_scope.with_all_tags(selected_tags) if selected_tags.present?
      static_scope = static_scope.search_by_name(query) if query.present?

      last_modified = static_scope.maximum(:updated_at) || Time.zone.at(0)
      etag = guest_boards_index_etag(last_modified, limit_param, tags: selected_tags)

      return unless stale?(etag: etag, last_modified: last_modified)

      static_scope = static_scope.order(order_clause)
      static_scope = static_scope.page(page).per(per_page)

      static_boards = static_scope.to_a
      payload = static_boards.map(&:api_view)

      render json: {
               boards: payload,
               public_tags: public_tags,
               pagination: {
                 page: static_scope.current_page,
                 per_page: static_scope.limit_value,
                 total_pages: static_scope.total_pages,
                 total_count: static_scope.total_count,
               },
             }
      return
    end

    # ---------------------------
    # 2. SEARCH MODE
    # ---------------------------
    if query.present?
      # Same set the default listing shows, so searching can't surface a board
      # the listing hides (or vice versa). Admins keep the wider `for_user`
      # view — DEFAULT_ADMIN_ID owns the predefined public library.
      search_scope = (current_user.admin? ? Board.for_user(current_user) : current_user.countable_boards).searchable
      search_scope = apply_filter(search_scope, filter)
      search_scope = search_scope.with_any_tags(selected_tags) if selected_tags.present?
      search_scope = search_scope.search_by_name(query)
      search_scope = search_scope.order(order_clause)
      search_scope = search_scope.page(page).per(per_page)

      last_updated_at = search_scope.maximum(:updated_at)&.to_i

      cache_key = [
        "boards-search-v4",
        current_user.id,
        query,
        filter || "no-filter",
        selected_tags.sort.join("|").presence || "no-tags",
        page,
        per_page,
        sort_field,
        sort_order,
        last_updated_at,
      ]

      result = Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
        boards_array = search_scope.to_a.map { |board| board.api_view(current_user) }

        {
          boards: boards_array,
          page: search_scope.current_page,
          per_page: search_scope.limit_value,
          total_pages: search_scope.total_pages,
          total_count: search_scope.total_count,
        }
      end

      render json: {
               boards: result[:boards],
               public_tags: public_tags,
               pagination: {
                 page: result[:page],
                 per_page: result[:per_page],
                 total_pages: result[:total_pages],
                 total_count: result[:total_count],
               },
             }
      return
    end

    # ---------------------------
    # 3. NORMAL MODE (no search)
    # ---------------------------
    # NOTE: deliberately no obf filter here. A user's OWN index shows their
    # imports, pages included; otherwise `boards.count` (which exposes
    # board_count in api_view) reports 6 while this listing renders 4. The
    # interior pages of an import are `sub_board: true`
    # (Boards::ImportedSetClassifier), so the default "Main Boards" filter
    # already collapses each imported set to its root — no obf-specific rule
    # needed on any of these listings.
    #
    # The listing IS the countable set, so an empty /boards next to a "1/1
    # boards" refusal can never happen again (issue #804). Admins are cap-exempt
    # and DEFAULT_ADMIN_ID owns the predefined public library, so they keep the
    # unfiltered view; for every other user the two scopes are identical apart
    # from published menus, which are free and flagged as such in api_view.
    base_scope = current_user.admin? ? current_user.boards : current_user.countable_boards
    filtered_scope = apply_filter(base_scope, filter)
    filtered_scope = filtered_scope.with_any_tags(selected_tags) if selected_tags.present?

    last_modified = boards_index_last_modified(current_user, filtered_scope)
    etag = boards_index_etag(
      current_user,
      per_page,
      filtered_scope,
      last_modified,
      filter: filter,
      sort_field: sort_field,
      sort_order: sort_order,
      page: page,
      tags: selected_tags,
    )

    return unless stale?(etag: etag, last_modified: last_modified)

    # Sub-pages sort after main boards on the unfiltered listing so the boards a
    # user actually made stay at the top now that folder pages are visible. The
    # named filters keep their own ordering.
    ordered_scope =
      if filter.blank? || filter == "countable" || filter == "all"
        filtered_scope.reorder(:sub_board).order(order_clause)
      else
        filtered_scope.reorder(order_clause)
      end

    user_boards_scope = ordered_scope
      .page(page)
      .per(per_page)

    @user_boards = user_boards_scope.to_a

    @newly_created_boards = filtered_scope
      .where("created_at >= ?", 1.week.ago)
      .reorder(created_at: :desc)
      .limit(7)
      .to_a

    render json: {
             newly_created_boards: @newly_created_boards.map { |board| board.api_view(current_user) },
             boards: @user_boards.map { |board| board.api_view(current_user) },
             public_tags: public_tags,
             counts: boards_index_counts(current_user, base_scope),
             pagination: {
               page: user_boards_scope.current_page,
               per_page: user_boards_scope.limit_value,
               total_pages: user_boards_scope.total_pages,
               total_count: user_boards_scope.total_count,
             },
           }
  end

  # Public (no-auth) list of boards offered for free PDF download to anonymous
  # lead-capture visitors. Reuses the curated public board gallery
  # (`Board.public_boards` — admin-owned, predefined + published) rather than a
  # separate flag, returned in the lean contract shape the frontend consumes.
  def free_download_boards
    boards = Board.public_boards.order(:name)
    render json: {
             boards: boards.map do |board|
               {
                 id: board.id,
                 name: board.name,
                 description: board.description,
                 image_url: board.display_image_url,
                 slug: board.slug,
                 public_url: board.public_url,
               }
             end,
           }
  end

  def public_boards
    if params["myspeak"] == "true"
      scope = Board.myspeak_public_boards.alphabetical
      if scope.count < 3
        scope = Board.public_boards.alphabetical
      end
      scope = scope.limit(10)
    else
      scope = Board.public_boards.alphabetical
    end

    last_modified = scope.maximum(:updated_at) || Time.zone.at(0)
    etag = public_boards_etag(scope, last_modified)

    return unless stale?(etag: etag, last_modified: last_modified)

    @public_boards = scope.to_a

    if params["myspeak"] == "true"
      # Surface the recommended starter board(s) first, then keep the
      # alphabetical order for the rest. api_view already exposes tags.
      @public_boards.sort_by! do |board|
        [board.tags.include?("myspeak-recommended") ? 0 : 1, board.name.to_s.downcase]
      end
    end

    render json: { public_boards: @public_boards.map { |board| board.api_view(current_user) } }
  end

  def list
    scope = current_user.boards.alphabetical

    last_modified = boards_list_last_modified(current_user, scope)
    etag = boards_list_etag(current_user, scope, last_modified)

    return unless stale?(etag: etag, last_modified: last_modified)

    @boards = scope.to_a

    render json: { boards: @boards.map { |board| board.list_api_view(current_user) } }
  end

  def common_boards
    @common_boards = Board.common_boards
    render json: { common_boards: @common_boards.map { |board| board.api_view(current_user) } }
  end

  def public_menu_boards
    @public_menu_boards = Board.public_menu_boards.alphabetical.all
    render json: { public_menu_boards: @public_menu_boards.map(&:api_view), public_tags: Board.public_boards_tags }
  end

  def categories
    @categories = Board.board_categories
    render json: @categories
  end

  def user_boards
    # @boards = boards_for_user.user_made_with_scenarios_and_menus.alphabetical
    @boards = current_user.boards.user_made_with_scenarios.alphabetical

    render json: { boards: @boards, dynamic_boards: current_user.boards.dynamic.alphabetical, public_tags: Board.public_boards_tags }
  end

  def predictive_image_board
    board = find_board_for_predictive_page

    voice = params[:voice].presence
    voice = "openai:alloy" if voice == "alloy"
    effective_voice = voice || board.voice

    last_modified = board_predictive_last_modified(board)

    etag = [
      board_predictive_etag(board, current_user),
      effective_voice,
    ]

    # TEMP Disable caching for predictive image board to ensure users see updates to their board immediately - will re-enable once we have better cache invalidation in place for this endpoint
    # return unless stale?(etag: etag, last_modified: last_modified, template: false)

    payload = RailsPerformance.measure("Predictive Image Board") do
      board.api_view_for_native_grid(current_user, false, effective_voice)
    end

    render json: payload
  end

  def show
    # if stale?(etag: @board, last_modified: @board.updated_at)
    #   RailsPerformance.measure("Show Board") do
    # @loaded_board = Board.with_artifacts.find(@board.id)
    unless @board
      render json: { error: "Board not found" }, status: :not_found
      Rails.logger.error "SHOW - Board not found for ID: #{params[:id]}"
      return
    end

    # `show` is unauthenticated (skip_before_action :authenticate_token!) and backs
    # the frontend `/pb/<slug>` route. Private (unpublished) boards must not leak to
    # non-owners — return the same generic 404 so we don't confirm the board exists.
    unless @board.viewable_by?(current_user)
      render json: { error: "Board not found" }, status: :not_found
      return
    end

    @board_with_images = @board.api_view_with_predictive_images(current_user, true)
    # end
    render json: @board_with_images
    # end
  end

  def initial_predictive_board
    @board = Board.predictive_default
    if @board.nil?
      @board = Board.with_artifacts.find_by(user_id: User::DEFAULT_ADMIN_ID, parent_type: "PredefinedResource")
      current_user.settings["dynamic_board_id"] = nil
      current_user.save!
    end
    render json: @board.api_view_with_images(current_user)
  end

  def save_layout
    set_board
    save_layout!

    @board.reload
    render json: @board.api_view_with_images(current_user)
  end

  def rearrange_images
    set_board
    @board.reset_layouts
    @board.save!
    broadcast_board_update!
    render json: @board.api_view_with_images(current_user)
  end

  def create
    @board = Board.new(board_params)
    @board.user = current_user
    board_type = params[:board_type] || board_params[:board_type]
    settings = !board_params[:settings].blank? ? board_params[:settings] : params[:settings] || {}
    settings["board_type"] = board_type
    @board.board_type = board_type || "static"
    @board.assign_parent

    creation_type = params[:board_creation_type] || "default"
    @board.board_type = creation_type

    @board.predefined = false
    # Only assign columns when the param is actually present. Blind .to_i
    # turns a missing param into 0, which suppresses Board#set_screen_sizes
    # defaults (which only fill in nil) and breaks downstream callers like
    # GenerateBoardJob's `large_screen_columns || 6` (0 is truthy in Ruby).
    @board.small_screen_columns = board_params["small_screen_columns"].to_i if board_params["small_screen_columns"].present?
    @board.medium_screen_columns = board_params["medium_screen_columns"].to_i if board_params["medium_screen_columns"].present?
    @board.large_screen_columns = board_params["large_screen_columns"].to_i if board_params["large_screen_columns"].present?
    voice = VoiceService.normalize_voice(board_params["voice"] || params[:voice] || params[:voice_label])
    @board.voice = voice
    @board.language = board_params["language"].presence || current_user.i18n_locale.to_s
    @board.tags = board_params["tags"] if board_params["tags"].present?
    @board.settings = settings

    new_slug = @board.generate_unique_slug(board_params["slug"])
    @board.slug = new_slug

    respond_to do |format|
      if @board.save
        # Clamp word_count server-side so a malicious/oversized client value
        # can't drive a huge AI prompt. The merged "Build a board" form sends
        # either camelCase (wordCount) or snake_case (word_count).
        word_count = (params[:wordCount].presence || params[:word_count].presence || 12).to_i.clamp(1, 50)
        case creation_type
        when "default", "scenario"
          # The redesigned /boards/new merges "from scratch" and "from
          # scenario" into one form, so topic (situation) and word_list (seed
          # words) can arrive together. The frontend picks the creation_type;
          # both paths share the same job args. age_range is optional —
          # GenerateBoardJob falls back to its own default when it's blank.
          word_list = params[:word_list]&.compact
          # Only "scenario" implies "generate words about this". A "default"
          # board (pasted word list, or start-blank) gets AI words ONLY when
          # the caller sent an explicit topic/prompt. Falling back to the
          # always-present board name here turned every create into an AI
          # generation, silently appending words nobody asked for (68a5fe35).
          topic     = params[:topic].presence || params[:prompt].presence
          topic     = @board.name if topic.blank? && creation_type == "scenario"
          age_range = params[:ageRange].presence || params[:age_range].presence

          job_args = {
            "topic"      => topic,
            "age_range"  => age_range,
            "word_count" => word_count,
            "profile"    => communicator_profile_params,
            # Ownership is checked here (profile_communicator scopes to the
            # caller); the job receives a pre-validated id.
            "communicator_id" => profile_communicator&.id,
          }
          job_args["word_list"] = word_list if word_list.present?

          GenerateBoardJob.perform_async(@board.id, creation_type, job_args)
        else
          GenerateBoardJob.perform_async(@board.id, creation_type, { "word_count" => word_count, "profile" => communicator_profile_params, "communicator_id" => profile_communicator&.id })
        end
        format.json { render json: @board, status: :created }
      else
        format.json { render json: @board.errors, status: :unprocessable_content }
      end
    end
  end

  # PATCH/PUT /boards/1 or /boards/1.json
  def update
    @board = Board.find(params[:id])
    @board_user = @board.user
    unless current_user.can_edit?(@board)
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    # Unpublishing and renaming a board that's sold as a printable are refused
    # outright — no confirm clears them. Unpublishing 404s /pb/<slug> for every
    # sheet already printed, and the name is the product's title. Both run
    # before any attribute is assigned, so a refusal writes nothing. Released
    # by waiving protection on the printable in the admin.
    if unpublishing_requested?
      return if render_marketplace_protection_conflict(@board, action: "unpublished")
    end

    if renaming_requested?
      return if render_marketplace_protection_conflict(@board, action: "renamed", blocked_action: "rename")
    end

    # Warn+confirm before cascading publish across a Board Builder set, mirroring
    # the delete flow. This runs BEFORE any attribute is assigned, so a declined
    # cascade writes nothing at all — the client re-sends the identical payload
    # with confirm=true. Reachable by any board owner since #633 let non-admins
    # set `published`; PublishCascade scopes its members to the root's owner so
    # a cascade can only ever flip boards the requester already owns.
    #
    # Skipped entirely when `image_ids_to_remove` is present: that branch
    # returns early below without ever assigning or saving `published`, so
    # there is nothing to confirm — and `board_params` (which calls
    # `params.require(:board)`) must not be evaluated on a request that may
    # carry no `board` key at all.
    if params["image_ids_to_remove"].blank? && board_params.key?("published")
      target_published = ActiveModel::Type::Boolean.new.cast(board_params["published"])
      # `.cast` maps nil/"" to nil, not false. `published` is a nullable
      # column, so a malformed value must not be treated as "unpublish" —
      # skip the cascade guard rather than let a nil target match (and
      # NULL out) every non-NULL member.
      if [true, false].include?(target_published) && target_published != @board.published
        cascade = Boards::PublishCascade.new(@board)
        # Before the confirm, and not confirmable: #apply! writes with
        # update_all, so a protected member page would be unpublished with no
        # callback to stop it.
        blocked = cascade.blocked_board_ids(published: target_published)
        return if render_marketplace_cascade_conflict_for_unpublish(blocked)

        if cascade.needed?(published: target_published) && params[:confirm].to_s != "true"
          render json: {
                   error: "publish_cascade_confirmation_required",
                   message: "\"#{@board.name}\" is the home of a board set — this change applies to every page in the set.",
                   board: { id: @board.id, name: @board.name },
                   cascade: cascade.summary(published: target_published),
                 }, status: :conflict
          return
        end
        @publish_cascade = cascade
        @publish_cascade_target = target_published
      end
    end

    if params["image_ids_to_remove"].present?
      image_ids_to_remove = params["image_ids_to_remove"]
      image_ids_to_remove.each do |image_id|
        image = Image.find(image_id)
        @board.remove_image(image&.id) if @board && image
      end
      render json: @board.api_view_with_images(current_user)
      return
    else
      @board.number_of_columns = board_params["number_of_columns"].to_i
      # Same guard as create: only assign columns when the param is actually
      # present so an omitted value doesn't silently overwrite saved columns
      # with 0.
      @board.small_screen_columns = board_params["small_screen_columns"].to_i if board_params["small_screen_columns"].present?
      @board.medium_screen_columns = board_params["medium_screen_columns"].to_i if board_params["medium_screen_columns"].present?
      @board.large_screen_columns = board_params["large_screen_columns"].to_i if board_params["large_screen_columns"].present?
      voice = VoiceService.normalize_voice(board_params["voice"] || params[:voice] || params[:voice_label])
      @board.voice = voice
      @board.name = board_params["name"] unless board_params["name"].blank?
      @board.description = board_params["description"]
      # The board cover (display image) is deliberately NOT set here. It's owned
      # by the dedicated endpoints (#set_display_image / #update_preset_display_image),
      # so a generic save (name/colors/tiles) can never clobber the chosen cover.
      @board.bg_color = board_params["bg_color"] if board_params["bg_color"].present?
      # Only assign when present. `predefined` is admin-only and stripped from
      # board_params for non-admins (#27), so a missing key must leave the saved
      # value untouched rather than null it out.
      @board.predefined = board_params["predefined"] if board_params.key?("predefined")
      @board.category = board_params["category"]
      @board.tags = board_params["tags"] if board_params["tags"].present?
      @board.language = board_params["language"] if board_params["language"].present?
      @board.favorite = board_params["favorite"] if board_params["favorite"].present?
      # `.key?`, not `.present?` — `false.present?` is false, so a `.present?`
      # guard silently drops `published: false` and makes unpublishing a no-op.
      # Matches the `predefined` guard above: a missing key leaves the saved
      # value untouched, an explicit false unpublishes. Cast and require a
      # real boolean so a malformed value (nil/"") can't NULL the column —
      # mirrors the cascade guard's own `[true, false]` check on the members.
      if board_params.key?("published")
        incoming_published = ActiveModel::Type::Boolean.new.cast(board_params["published"])
        @board.published = incoming_published unless incoming_published.nil?
      end
      # A slug is derived from the name ONCE, at creation. Renaming a board must
      # NOT re-key its URL: `/pb/<slug>` is what a shared link and a printed QR
      # code point at, and the frontend used to re-derive the slug on every
      # keystroke of the name field, so an ordinary rename silently moved an
      # unpublished board's public URL out from under anyone holding the link.
      #
      # Changing the slug is now deliberate and admin-only (`:slug` and
      # `:regenerate_slug` are stripped from board_params for non-admins). The
      # three ways an admin asks for a change, in order:
      #
      #   1. `regenerate_slug: true`  — the "Generate slug from name" toggle
      #   2. `slug: ""`               — clearing the Slug field in BoardForm
      #   3. `slug: "something-else"` — typing a slug by hand
      #
      # A blank stored slug is backfilled from the name regardless: `validates
      # :slug, uniqueness: true` does not skip blanks (see #build_obf_placeholder_board).
      #
      # On a PUBLISHED board every one of these is still reverted by
      # Board#freeze_published_slug — printed paper can't be re-issued (#611).
      # Deliberate published renames go through the internal API's `force_slug`
      # or the `boards:rename_slug` rake task.
      regenerate_slug = ActiveModel::Type::Boolean.new.cast(board_params["regenerate_slug"])
      slug_cleared = board_params.key?("slug") && board_params["slug"].blank?

      if @board.slug.blank? || regenerate_slug || slug_cleared
        @board.generate_unique_slug(@board.name)
      elsif board_params["slug"].present? && board_params["slug"] != @board.slug
        @board.generate_unique_slug(board_params["slug"])
      end

      @board.vendor_id = current_user.vendor_id if current_user.vendor_id.present?

      board_type = params[:board_type] || board_params[:board_type]
      settings = !board_params[:settings].blank? ? board_params[:settings] : params[:settings] || {}
      settings["board_type"] = board_type

      # Never stomp a Menu/Image/Board/OpenaiPrompt parent here — that link is
      # the board's provenance and nothing else records it. See
      # Board#sync_user_parent.
      @board.sync_user_parent(@board_user&.id)
      new_board_settings = @board.settings.merge(settings)
      @board.settings = new_board_settings

      @board.set_text_color(board_params["text_color"]) if board_params["text_color"].present?

      word_list = params["word_list"] || []
      duplicate_words = params[:duplicate_words] || false
      words_to_create = []
      current_word_list = @board.current_word_list
      word_list.each do |word|
        if word.is_a?(String) && word.present?
          if current_word_list.include?(word) && !duplicate_words
            next
          end
          words_to_create << word
        end
      end

      if !words_to_create.blank?
        @board.find_or_create_images_from_word_list(words_to_create)
      end

      @board.set_current_word_list

      # Persist spacing/margins here so changing only the spacing sliders is
      # saved. Margins used to ride along inside save_layout!, which the update
      # action only invokes when the tile layout itself changed — so a
      # margins-only edit (no tile moved) was silently dropped and snapped back
      # to the stored/default value on refetch.
      if params[:xMargin].present? && params[:yMargin].present?
        margin_screen_size = params[:screen_size] || "lg"
        margins = @board.margin_settings || {}
        margins[margin_screen_size] = {
          "x" => params[:xMargin].to_i,
          "y" => params[:yMargin].to_i,
        }
        @board.margin_settings = margins
      end

      # The root's save and the set cascade share one transaction: a failed
      # cascade must not leave the root published with its members behind.
      #
      # `raise ActiveRecord::Rollback unless saved` is not what protects that
      # invariant — when `@board.save` returns false nothing was written, so
      # there is nothing to roll back. The real protection is `apply!`
      # raising and propagating out of this block, which aborts the
      # transaction and leaves the root's save uncommitted too. Also note:
      # under transactional fixtures this block has no savepoint of its own,
      # so a spec asserting "a cascade failure rolls back the root" would
      # pass vacuously here — such a spec needs `requires_new: true` to
      # actually exercise a rollback.
      saved = false
      ActiveRecord::Base.transaction do
        saved = @board.save
        raise ActiveRecord::Rollback unless saved
        @publish_cascade&.apply!(published: @publish_cascade_target)
      end

      respond_to do |format|
        if saved
          if params[:layout].present?
            # only save if changes are present
            layout_param = params[:layout]
            if layout_param.is_a?(Array)
              layout = layout_param.map(&:to_unsafe_h) # Convert ActionController::Parameters to a Hash
              screen_size = params[:screen_size] || "lg"
              if @board.layout[screen_size] != layout
                @layout = layout
                save_layout!
              end
            else
              screen_size = layout_param["screen_size"] || "lg"
              layout = layout_param["layout"] || []
              Rails.logger.debug "Received layout for screen size #{screen_size}: #{layout.inspect}"
              @layout = layout.map(&:to_unsafe_h) # Convert ActionController::Parameters to a Hash
              if @board.layout[screen_size] != @layout
                save_layout!
              end
            end
          end
          broadcast_board_update!
          format.json { render json: @board.api_view_with_images(current_user), status: :ok }
        else
          format.json { render json: @board.errors, status: :unprocessable_content }
        end
      end
    end
  end

  def regenerate_images
    set_board
    return unless check_credits!(feature_key: "image_generation", feature_name: "AI Image Regeneration")
    board_image_ids = params[:board_image_ids]
    if board_image_ids.blank? || !board_image_ids.is_a?(Array)
      render json: { error: "board_image_ids parameter is required and must be an array" }, status: :unprocessable_content
      return
    end
    board_images = @board.board_images.where(id: board_image_ids)
    if board_images.empty?
      render json: { error: "No valid board images found for the provided IDs" }, status: :unprocessable_content
      return
    end
    image_ids = board_images.pluck(:image_id)
    image_ids.each_slice(3) do |batch|
      GenerateImagesJob.perform_async(batch, @board.id)
    end
    render json: { status: "ok", message: "Image regeneration job started" }
  end

  def recategorize_images
    set_board
    return unless check_credits!(feature_key: "board_format", feature_name: "AI Image Recategorization")
    board_image_ids = @board.board_images.pluck(:id)
    board_image_ids.each_slice(20) do |batch|
      RecategorizeImagesJob.perform_async("BoardImage", batch)
    end
    render json: { status: "ok", message: "Recategorization job started for board images" }
  end

  def update_to_default_docs
    set_board
    if params[:board_image_ids].present? && params[:board_image_ids].is_a?(Array)
      @board_images = @board.board_images.where(id: params[:board_image_ids])
    else
      @board_images = @board.board_images
    end
    @board_images.each do |board_image|
      board_image.update_to_default_doc!
    end
    @board.update_column(:updated_at, Time.current) # update timestamp to reflect change
    render json: @board.api_view_with_images(current_user)
  end

  def set_colors
    set_board
    results = []
    @board.board_images.each do |board_image|
      results << board_image.set_colors!
    end
    if results.all? { |res| res == true }
      render json: @board.api_view_with_images(current_user)
    else
      Rails.logger.error "Setting colors failed for some images: #{results.inspect}"
      render json: { error: "Setting colors failed for some images" }, status: :unprocessable_content
    end
  end

  # Switch which image represents the board (its cover / thumbnail):
  #   source=preview                        → the auto-generated grid snapshot
  #   source=custom, display_image_url=<url> → a specific tile's picture
  # A custom cover the user *uploads* goes through #update_preset_display_image
  # instead (also source=custom). This is the ONLY place a generic caller flips
  # the switch, so a normal board save can't disturb the cover.
  def set_display_image
    set_board
    source = params[:source].to_s

    case source
    when "preview"
      @board.settings = (@board.settings || {}).merge("display_image_source" => "preview")
      @board.save!
    when "custom"
      src = params[:display_image_url].presence
      if src.blank?
        render json: { error: "display_image_url is required when source is custom" }, status: :unprocessable_content
        return
      end
      @board.write_attribute(:display_image_url, src)
      @board.settings = (@board.settings || {}).merge("display_image_source" => "custom")
      @board.save!
    else
      render json: { error: "source must be 'preview' or 'custom'" }, status: :unprocessable_content
      return
    end

    render json: @board.api_view_with_images(current_user)
  end

  def update_preset_display_image
    set_board
    image_data = board_params[:preset_display_image]
    if image_data.blank?
      render json: { error: "No image data provided" }, status: :unprocessable_content
      return
    end

    file_extension = board_params[:preset_display_image]
    file_extension = file_extension.content_type.split("/").last if file_extension
    attach_image_to_board(image_data, file_extension)
    render json: @board.api_view_with_images(current_user)
  end

  def download_obf
    set_board
    return if performed?

    # Same generic 404 as #show: never confirm a private board exists.
    unless @board.viewable_by?(current_user)
      render json: { error: "Board not found" }, status: :not_found
      return
    end

    result = Boards::ObfExporter.new(@board, exporting_user: current_user, asset_mode: :inline).call
    filename = "#{@board.name.to_s.parameterize.presence || "board"}.obf"

    send_data result.obf.to_json, filename: filename,
                                  type: "application/json", disposition: "attachment"
  rescue Boards::ObfExporter::TooLarge => e
    # error_code (not the exception message, which stays internal) is what
    # lets a client distinguish "too many tiles" from "too many bytes" — and
    # what makes the cause visible in logs when a user reports a failed
    # export.
    render json: {
      error: "Board is too large to export synchronously",
      error_code: e.code,
      export_package_url: export_package_api_board_path(@board),
    }, status: :unprocessable_content
  end

  def export_package
    set_board
    return if performed?

    unless @board.viewable_by?(current_user)
      render json: { error: "Board not found" }, status: :not_found
      return
    end

    if current_user.board_exports.in_flight.exists?
      render json: { error: "export_in_progress" }, status: :conflict
      return
    end

    record = BoardExport.create!(user: current_user, exportable: @board, file_format: "obz")
    ExportBoardPackageJob.perform_async(record.id)

    render json: record.api_view, status: :created
  end

  def analyze_obz
    uploaded_file = params[:file]
    if uploaded_file.blank?
      render json: { error: "No file or data provided" }, status: :unprocessable_content
      return
    end

    report = ObzAnalyzer.analyze(uploaded_file.read)
    render json: report
  end

  def import_obf
    # Image binaries (e.g. licensed SymbolStix PNGs) are NEVER pulled in by
    # default. The client must opt in with `include_images=true` AND confirm
    # via `image_license_acknowledged=true`. Newly-created Images are always
    # is_private (see Board.find_or_create_image_for_button).
    import_options, ack_error = parse_obf_import_options
    if ack_error
      render json: ack_error, status: :bad_request
      return
    end

    if params[:file].present?
      uploaded_file = params[:file]
      file_name = uploaded_file.original_filename
      group_name = params[:group_name] || "Imported #{file_name || Time.now.to_i}"
      file_extension = File.extname(file_name).downcase

      if file_extension == ".obz"
        begin
          @board_group = BoardGroup.create!(name: group_name, user_id: current_user.id, status: "queued")
          @board_group.import_source_file.attach(uploaded_file)
        rescue => e
          Rails.logger.error "OBZ import failed: #{e.message}"
          render json: { error: "OBZ import failed: #{e.message}" }, status: :unprocessable_content
          return
        end

        ImportObzJob.perform_async(@board_group.id, current_user.id, import_options.stringify_keys)

        render json: {
          status: "ok",
          message: "Importing OBZ file #{file_name}",
          board_group_id: @board_group.id,
          import_status: @board_group.status,
          include_images: import_options[:include_images],
        }, status: :accepted
      elsif file_extension == ".obf"
        json_data = parse_obf_upload(uploaded_file)
        unless json_data
          render json: { error: "Invalid OBF file: expected a JSON board document" },
                 status: :unprocessable_content
          return
        end

        board = build_obf_placeholder_board(json_data)
        unless board
          render json: { error: "OBF import failed: could not create the board" },
                 status: :unprocessable_content
          return
        end

        # Sidekiq serializes args to JSON — pass string-keyed hash.
        ImportFromObfJob.perform_async(json_data, current_user.id, nil, import_options.stringify_keys, board.id)
        render json: {
          status: "ok",
          message: "Importing OBF file #{file_name}",
          board_id: board.id,
          import_status: board.status,
          include_images: import_options[:include_images],
        }, status: :accepted
      else
        render json: { error: "Unsupported file format" }, status: :unprocessable_content
      end
    elsif params[:data].present?
      boardData = params[:data]&.to_json
      params[:board_group_id] = params[:board_group_id].to_i
      board_group = BoardGroup.find_by(id: params[:board_group_id]) if params[:board_group_id].present?

      json_data = JSON.parse(boardData) rescue nil
      unless json_data
        render json: { error: "Invalid JSON data" }, status: :unprocessable_content
        return
      end
      board_name = json_data["name"] || "Imported Board"

      board = build_obf_placeholder_board(json_data)
      unless board
        render json: { error: "OBF import failed: could not create the board" },
               status: :unprocessable_content
        return
      end

      # Sidekiq serializes args to JSON — pass string-keyed hash.
      ImportFromObfJob.perform_async(json_data, current_user.id, board_group&.id, import_options.stringify_keys, board.id)
      render json: {
        status: "ok",
        message: "Importing OBF data for board #{board_name}",
        board_id: board.id,
        import_status: board.status,
        include_images: import_options[:include_images],
      }, status: :accepted
    else
      render json: { error: "No file or data provided" }, status: :unprocessable_content
    end
  end

  # The .obz branch creates its BoardGroup inside the request, so a failure is
  # a visible 422 and the response carries an id the client can poll while the
  # job runs. The .obf branch does the same with the Board itself — without an
  # id there is nothing for the frontend to follow, and a failure in the job is
  # invisible to the user.
  #
  # `generate_unique_slug` is load-bearing: `boards.slug` defaults to "" and
  # `validates :slug, uniqueness: true` does not skip blanks, so a board saved
  # without one collides with the first slug-less row in the table.
  def build_obf_placeholder_board(json_data)
    board = Board.new(
      name: json_data["name"].presence || "Imported Board",
      user: current_user,
      status: "queued",
    )
    board.assign_parent
    board.generate_unique_slug
    board.save!
    board
  rescue => e
    Rails.logger.error "[import_obf] could not create the board to import into: #{e.message}"
    nil
  end

  # A bare .obf upload is a single JSON board document (an .obz is a zip of
  # them). Returns the parsed Hash, or nil if the upload isn't one — the
  # caller turns nil into a 422 rather than letting the job fail silently in
  # the background.
  def parse_obf_upload(uploaded_file)
    parsed = JSON.parse(uploaded_file.read)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError => e
    Rails.logger.error "OBF import: unparseable upload: #{e.message}"
    nil
  end

  # Pulls the three opt-in params off the request and validates that
  # `image_license_acknowledged` accompanies `include_images=true`. Returns
  # [options_hash, error_response_or_nil].
  def parse_obf_import_options
    include_images = ActiveModel::Type::Boolean.new.cast(params[:include_images]) || false
    ack = ActiveModel::Type::Boolean.new.cast(params[:image_license_acknowledged]) || false

    if include_images && !ack
      return [nil, {
        error: "image_license_required",
        message: "include_images=true requires image_license_acknowledged=true. " \
                 "Imports must confirm permission to use the bundled images.",
      }]
    end

    [{
      include_images: include_images,
      license_acknowledged: ack,
      acknowledged_by_user_id: ack ? current_user.id : nil,
    }, nil]
  end

  def additional_words
    set_board
    num_of_words = params[:num_of_words].to_i || 10
    board_words = @board.board_images.map(&:label).uniq
    name_to_send = params[:prompt] || params[:name] || @board.name
    profile = CommunicatorProfile.for(params: params, communicator: profile_communicator)
    resolved_language = params[:language].presence || @board.language.presence || "en"
    additional_words = @board.get_words(name_to_send, num_of_words, board_words, current_user.admin?, language: resolved_language, profile: profile)
    render json: additional_words
  end

  def get_description
    set_board
    description = @board.get_description
    render json: { description: description }
  end

  def words
    if params[:name].blank?
      render json: { error: "Name parameter is required" }, status: :unprocessable_content
      return
    end
    if params[:num_of_words].blank? || params[:num_of_words].to_i <= 0
      render json: { error: "num_of_words parameter must be a positive integer" }, status: :unprocessable_content
      return
    end
    if params[:num_of_words].to_i > 50
      render json: { error: "num_of_words parameter cannot exceed 50" }, status: :unprocessable_content
      return
    end
    if params[:board_id].present?
      @board = Board.find_by(id: params[:board_id])
    end
    return unless check_credits!(feature_key: "word_suggestion", feature_name: "AI Word Suggestions")
    creation_type = params[:board_creation_type] || "default"
    additional_words = []
    prompt = params[:prompt].presence || params[:name]
    num_of_words = params[:num_of_words].to_i || 24
    words_to_exclude = parse_words_to_exclude(params[:words_to_exclude]).presence ||
                       @board&.current_word_list || []
    profile = CommunicatorProfile.for(params: params, communicator: profile_communicator)
    @board ||= Board.new(name: prompt) # create a temporary board object to use the word suggestion methods if no board_id is provided
    # Source language from explicit param first, then board.language, then user
    # locale — so a Spanish-language board produces Spanish suggestions even
    # when the user's locale is English, and a transient (board-less) request
    # still picks up the user's locale.
    resolved_language = params[:language].presence ||
                        @board&.language.presence ||
                        current_user.i18n_locale.to_s
    if creation_type == "social_story"
      number_of_steps = params[:number_of_steps].to_i
      additional_words = @board.get_social_story_word_suggestions(prompt, number_of_steps, num_of_words, words_to_exclude, language: resolved_language)
    elsif creation_type == "predictive"
      additional_words = @board.get_words_for_predictive(prompt, num_of_words, language: resolved_language, profile: profile)
    elsif creation_type == "custom"
      text = "Please give a list of #{num_of_words} words/phrases based on the following prompt: #{prompt} \n These will be used to create an AAC board so keep that in mind. Use lower case unless it's a proper noun and avoid special characters. Do not include any words on the board already: #{words_to_exclude.join(", ")}."
      additional_words = @board.get_word_suggestions_from_prompt(text, language: resolved_language, profile: profile,
                                                                       existing_words: words_to_exclude)
    else
      # ONE prompt path. This used to fork on `prompt == @board.name` into a
      # second, much weaker prompt builder — one whose user turn named no topic
      # and asked only for a count, leaving the whole-board coverage rules in
      # the system prompt as the only selection guidance. Since the editor seeds
      # the override field with the board name and sends it verbatim, "left the
      # field alone" was indistinguishable from "typed the board name", so the
      # default case took the weak branch every time and a board called "Places"
      # came back with "different", "again", "something else", "all done" —
      # strings copied straight out of Prompts::Aac::OBJECTION_REDIRECT_RULE.
      #
      # No menu branch either: get_word_suggestions_from_default_prompt already
      # special-cases a menu board internally, so a separate one only offered a
      # second place for the two to disagree.
      additional_words = @board.get_word_suggestions_from_default_prompt(
        prompt,
        num_of_words,
        words_to_exclude: words_to_exclude,
        language: resolved_language,
        profile: profile,
      )
    end
    if additional_words.blank?
      Rails.logger.error "No additional words found for prompt: #{prompt} - creation_type: #{creation_type}"
      render json: { error: "No additional words found" }, status: :unprocessable_content
      return
    end
    unless additional_words.is_a?(Array)
      Rails.logger.error "Invalid response from word suggestion service: #{additional_words.inspect}"
      render json: { error: "Invalid response from word suggestion service" }, status: :unprocessable_content
      return
    end
    normalize_words = additional_words.map do |word|
      next unless word.is_a?(String)
      word.gsub("_", " ").strip
    end
    render json: normalize_words
  end

  def format_with_ai
    return unless check_credits!(feature_key: "board_format", feature_name: "AI Board Formatting")
    set_board
    screen_size = params[:screen_size] || "lg"
    options = {
      "board_id" => @board.id,
      "user_id" => current_user.id,
      "screen_size" => screen_size,
    }
    FormatBoardWithAiJob.perform_async(options)
    @board.update(status: "formatting")
    render json: @board.api_view_with_images(current_user)
  end

  def add_image
    set_board
    # @board = Board.with_artifacts.find(params[:id])
    # acting_user throughout: on a communicator token current_user is nil, and
    # everything created here belongs to the adult who owns the account.
    @found_image = Image.by_label(image_params[:label]).find_by(user_id: acting_user.id, private: true)
    @found_image ||= Image.by_label(image_params[:label]).first
    if @found_image
      @image = @found_image
      img_saved = true
    else
      @image = Image.new
      @image.user = acting_user
      @image.label = image_params[:label]
      # part_of_speech: "phrase" distinguishes gestalt whole-phrase tiles
      # (Script Collector) from single-word tiles. Optional; falls back to the
      # model default otherwise.
      @image.part_of_speech = image_params[:part_of_speech] if image_params[:part_of_speech].present?
      img_saved = @image.save!
    end

    new_doc = nil
    if (image_params[:docs].present?)
      owns_image = @image.user_id == acting_user.id
      # Only mutate the image's "current" doc flags if the current user owns
      # the image. Otherwise we'd be flipping global display state on someone
      # else's image (or a shared/admin image) just because this user uploaded
      # their own variant.
      @image.docs.where(current: true).update_all(current: false) if owns_image
      new_doc = @image.docs.new(image_params[:docs])
      new_doc.user = acting_user
      new_doc.processed = true
      new_doc.source_type = Doc::SOURCE_TYPE_USER
      new_doc.current = true if owns_image
      new_doc.save
    end
    if img_saved
      board_image = @board.add_image(@image.id) if @board

      # Surface the uploaded doc on this board, even when the user doesn't own
      # the underlying image. Mirrors DocsController#mark_as_current, which
      # also updates board_image.display_image_url per-board.
      if new_doc&.persisted? && @board
        board_image ||= @board.board_images.find_by(image_id: @image.id)
        board_image&.update(display_image_url: new_doc.tile_url)
      end

      # Gestalt-specific tile metadata (Script Collector). Free-form: where the
      # phrase came from and what communicative function it serves. Stored on
      # board_images.data jsonb alongside any existing keys.
      gestalt = gestalt_metadata
      if gestalt.present? && @board
        board_image ||= @board.board_images.find_by(image_id: @image.id)
        board_image&.update(data: (board_image.data || {}).merge(gestalt))
      end

      # "Link a board" (the Add-tiles modal's third tab): make the tile we just
      # created open one of the caller's existing boards. Top-level param, not
      # part of image_params — it describes the tile, not the Image. Absent
      # means a plain word tile, which is the pre-existing behaviour.
      if params[:predictive_board_id].present? && @board
        board_image ||= @board.board_images.find_by(image_id: @image.id)
        target = linkable_board(params[:predictive_board_id])
        # A tile pointing at its own board is not a link. BoardImage#is_dynamic?
        # rejects the self-case and api_view_with_predictive_images forces
        # dynamic=false for a tile aimed at the root board, so it would render
        # as an ordinary tile with no folder badge and no navigation. Drop it
        # rather than storing a link that silently does nothing.
        target = nil if target && target.id == @board.id
        if board_image && target
          board_image.predictive_board_id = target.id
          # mute_name is not merely "don't speak": it is what makes
          # BoardImage#door_tile? true, which is what the board-set map reads to
          # draw the folder edge. Merge — the gestalt block above writes the
          # same jsonb blob.
          board_image.data = (board_image.data || {}).merge("mute_name" => true)
          # Fall back to the linked board's cover only when the resolved Image
          # brought no art of its own. A blank string is the deliberate
          # "no picture" marker, so this must never assign "".
          if board_image.display_image_url.blank? &&
             @image.display_image_url(acting_user).blank? &&
             target.display_image_url.present?
            board_image.display_image_url = target.display_image_url
          end
          board_image.save
        end
      end

      screen_size = params[:screen_size] || "lg"
      # @board.calculate_grid_layout_for_screen_size(screen_size)
      @board.reload
      @board_with_images = @board.api_view_with_images(acting_user)
      broadcast_board_update!

      render json: @board_with_images
    else
      render json: img_saved.errors, status: :unprocessable_content
    end
  end

  # Quick add: drop a curated set of words (Boards::WordPacks) onto the board.
  #
  # The client names a PACK KEY and the subset of that pack's words it wants;
  # the server owns the vocabulary and the part of speech. Anything not in the
  # named pack is dropped rather than 422'd — a stale client asking for a word
  # a pack no longer carries should add the rest, not fail.
  #
  # Costs nothing and must stay that way. `max_generate: 0` means no
  # GenerateImagesJob is ever enqueued (a word with no library art lands as a
  # picture-less tile, which the client warned about before the add), and the
  # authored part_of_speech means Image#ensure_defaults skips the synchronous
  # AacWordCategorizer OpenAI call it would otherwise make per novel word.
  def add_word_pack
    # Already resolved by check_board_editable!; the guard is for the shape, not
    # a second query.
    set_board if @board.nil?
    return if performed? || @board.nil?

    pack = Boards::WordPacks.find(params[:pack_key])
    unless pack
      render json: { error: "word_pack_not_found", message: "We don't have that set of words." },
             status: :not_found
      return
    end

    words = Boards::WordPacks.requested_words(pack[:key], params[:words])
    # Skip what's already here. The picker greys these out, but two tabs or a
    # stale payload shouldn't produce duplicate tiles.
    already = @board.current_word_list.map { |w| Boards::WordPacks.normalize_key(w) }.to_set
    words = words.reject { |word| already.include?(Boards::WordPacks.normalize_key(word)) }

    if words.any?
      @board.find_or_create_images_from_word_list(
        words,
        max_generate: 0,
        parts_of_speech: Boards::WordPacks.part_of_speech_map(pack[:key], words),
      )
      @board.reload
    end

    @board_with_images = @board.api_view_with_images(current_user)
    broadcast_board_update! if words.any?

    render json: @board_with_images.merge(words_added: words), status: :ok
  end

  def associate_image
    # Issue #26 (IDOR): a user may add their own image or any public library
    # image to a board, but not reference another user's PRIVATE image. A
    # non-owner asking for someone else's private image gets a 404. Admins bypass.
    @image = if current_user.admin?
      Image.find(params[:image_id])
    else
      Image.where("images.is_private IS NOT TRUE OR images.user_id = ?", current_user.id).find(params[:image_id])
    end
    screen_size = params[:screen_size] || "lg"
    if @board.images.include?(@image)
      render json: { error: "Image already associated with board" }, status: :unprocessable_content
      return
    end
    if @board.predefined && !current_user.admin?
      render json: { error: "Cannot add images to predefined boards" }, status: :unprocessable_content
      return
    end

    new_board_image = @board.add_image(@image.id) if @board
    notice = "Image added to board"
    if new_board_image
      broadcast_board_update!
      render json: @board.api_view_with_images(current_user), notice: notice
    else
      render json: { error: "Error adding image to board" }, status: :unprocessable_content
    end
  end

  def associate_images
    images = Image.where(id: params[:image_ids])
    screen_size = params[:screen_size] || "lg"
    if @board.images.include?(images)
      render json: { error: "Image already associated with board" }, status: :unprocessable_content
      return
    end

    if @board.predefined && !current_user.admin?
      render json: { error: "Cannot add images to predefined boards" }, status: :unprocessable_content
      return
    end

    new_board_images = []
    images.each do |image|
      if @board.images.include?(image)
        next
      end
      new_board_image = @board.board_images.new(image_id: image.id, position: @board.board_images_count)
      new_board_image.layout = new_board_image.initial_layout
      new_board_image.save
      new_board_images << new_board_image
    end

    broadcast_board_update!
    render json: { board: @board, new_board_images: new_board_images }
  end

  def add_to_groups
    @board = Board.find(params[:id])

    if params[:board_group_ids].blank?
      render json: { error: "No board group IDs provided" }, status: :unprocessable_content
      return
    elsif params[:board_group_ids].is_a?(String)
      board_group_ids = params[:board_group_ids].split(",").map(&:strip).map(&:to_i)
    elsif params[:board_group_ids].is_a?(Array)
      board_group_ids = params[:board_group_ids].map(&:to_i)
    else
      render json: { error: "Invalid board group IDs format" }, status: :unprocessable_content
      return
    end
    board_group_ids.each do |board_group_id|
      board_group = BoardGroup.find_by(id: board_group_id)
      Rails.logger.debug "Processing board group #{board_group.id} for board #{@board.id}"
      if board_group.nil?
        Rails.logger.error "Board group with ID #{board_group_id} not found"
        next
      end
      if board_group.boards.include?(@board)
        Rails.logger.debug "Board #{@board.id} already exists in group #{board_group.id}"
      else
        Rails.logger.debug "Adding board #{@board.id} to group #{board_group.id}"
        board_group.add_board(@board)
        board_group.save
      end
    end
    @board.reload
    # render json: { message: "Board added to groups successfully" }
    @board_with_images = @board.api_view_with_predictive_images(current_user, true)
    # end
    render json: @board_with_images
  end

  def assign_accounts
    communicator_account_ids = params[:communicator_account_ids] || []
    if communicator_account_ids
      record_errors = []
      if communicator_account_ids.is_a?(String) || communicator_account_ids.is_a?(Integer)
        communicator_account_ids = [communicator_account_ids.to_i]
      end
      assigned = []
      communicator_account_ids.each do |communicator_account_id|
        communicator_account = ChildAccount.find(communicator_account_id)

        # Already on this dashboard: nothing to do, and nothing to charge
        # against either cap.
        if communicator_account.child_boards.exists?(board_id: @board.id)
          assigned << communicator_account.id
          next
        end

        if communicator_account.sandbox?
          demo_limit = (communicator_account.settings["demo_board_limit"] || ChildAccount::DEMO_ACCOUNT_BOARD_LIMIT).to_i
          # Same semantics as assign_boards: count what the dashboard WOULD
          # hold. The two endpoints used to disagree (`>` here, `>=` there) on
          # one cap.
          if communicator_account.child_boards.count + 1 > demo_limit
            record_errors << "Board limit reached for demo account #{communicator_account.name} - limit: #{demo_limit}"
            next
          end
        end
        # Assignment attaches rather than copying, so it spends no board slot.
        # This per-communicator cap bounds how big one dashboard can get.
        if communicator_account.at_assigned_board_limit?
          record_errors << "Board limit reached for #{communicator_account.name} - limit: #{ChildAccount.max_assigned_boards}"
          next
        end

        # Same allowlist as assign_boards, from the other direction: the board
        # is fixed and the communicators vary, but the caller still has to be
        # allowed to put THIS board on a dashboard.
        if Boards::AssignableSource.new(communicator_account, actor: current_user).resolve(@board.id).nil?
          record_errors << "Could not assign board to #{communicator_account.name}"
          next
        end

        begin
          # ATTACH, don't copy — see assign_boards.
          communicator_account.child_boards.find_or_create_by!(board: @board) do |cb|
            cb.created_by_id = current_user.id
          end
          assigned << communicator_account.id
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
          Rails.logger.error "[assign_accounts] #{e.message}"
          record_errors << "Could not assign board to #{communicator_account.name}"
        end
      end

      # `in_use` is maintained by ChildBoard's create/destroy callbacks
      # (recalculate_boards_in_use); setting it here as well made detaching the
      # last dashboard unable to clear it.
      @board.reload
      if record_errors.empty?
        render json: @board.api_view_with_predictive_images(current_user, true), status: :ok
      else
        # A partial success used to report only the failures, so the caller
        # could not tell which communicators actually got the board.
        render json: { error: { message: record_errors }, assigned_account_ids: assigned },
               status: :unprocessable_content
      end
    else
      render json: { error: { message: "No board_ids provided" } }, status: :unprocessable_content
    end
  end

  def remove_image
    if @board.predefined && !current_user.admin?
      render json: { error: "Cannot remove images from predefined boards" }, status: :unprocessable_content
      return
    end
    @board_image = BoardImage.find_by(id: params[:board_image_id])
    @board.remove_board_image(@board_image&.id) if @board && @board_image
    @board.reload
    render json: @board.api_view_with_predictive_images(current_user)
  end

  # # DELETE /boards/1 or /boards/1.json
  #
  # Warn+confirm: deleting a board that's still in use (a folder tile on
  # another board points at it, it's on a communicator dashboard, shared with
  # a team, or it's a Board Builder root) returns 409 with a usage summary
  # unless the client re-sends with confirm=true. Boards nothing references
  # delete in one step, as before. Folder tiles pointing at the deleted board
  # are nullified by the predictive_board_images dependent: :nullify
  # association (all board types — the old manual loop here only covered
  # board_type "predictive" and was redundant).
  #
  # A board with subboards of its own (folder tiles pointing OUT at other
  # boards) also counts as in use, so the confirm carries a subboard summary
  # and the client can opt into the cascade with delete_subboards=true.
  def destroy
    usage = Boards::UsageCheck.new(@board)

    # Marketplace protection is checked FIRST and separately from UsageCheck.
    # `board_in_use` is a confirmable 409 — the client's correct response is to
    # resend with confirm=true — and this one can't be confirmed away. Showing
    # the confirmable warning first would teach the client to retry into a wall.
    return if render_marketplace_protection_conflict(@board, action: "deleted")

    if (group = usage.builder_group)
      # The group cascade destroys every member board, so a protected member
      # has to be caught before group.destroy! reaches the model guard — a raise
      # from inside destroy_all would be a 500, not a 409.
      blocked = Boards::MarketplaceProtection.protected_board_ids(
        group.board_group_boards.pluck(:board_id),
      )
      return if render_marketplace_cascade_conflict(blocked, key: :blocked_boards)
    elsif params[:delete_subboards].to_s == "true"
      # Refuse the WHOLE cascade rather than skipping the protected child:
      # skipping would delete the parent and leave the protected page behind
      # with a folder tile pointing at nothing, which is the corruption this
      # feature exists to prevent.
      blocked = Boards::MarketplaceProtection.protected_board_ids(
        usage.subboard_tree&.deletable_ids || [],
      )
      return if render_marketplace_cascade_conflict(blocked, key: :blocked_subboards)
    end

    if usage.in_use? && params[:confirm].to_s != "true"
      render json: {
               error: "board_in_use",
               message: "\"#{@board.name}\" is still in use — deleting it will remove it from the boards, communicators, or teams that reference it.",
               board: { id: @board.id, name: @board.name },
               usage: usage.summary,
             }, status: :conflict
      return
    end

    # A builder root's tree is owned by its builder BoardGroup (issue #407);
    # destroying the group cascades every member board. Routing lives HERE,
    # not in a Board callback — a before_destroy on Board that destroyed the
    # group would recurse with the group's destroy_all of its members.
    if (group = usage.builder_group)
      group.destroy!
    elsif params[:delete_subboards].to_s == "true"
      # Opt-in cascade: also destroy the board's own subboard tree, minus any
      # subboard something outside the tree still depends on (Boards::SubboardTree
      # decides). All-or-nothing so a mid-tree failure can't leave a half-deleted
      # set behind.
      ActiveRecord::Base.transaction do
        Board.where(id: usage.subboard_tree&.deletable_ids).find_each(&:destroy!)
        @board.destroy!
      end
    else
      @board.destroy!
    end

    respond_to do |format|
      format.json { head :no_content }
    end
  end

  def add_to_team
    @team = Team.find(params[:team_id])
    @board = Board.find(params[:id])
    @team.boards << @board
    render json: @team.show_api_view
  end

  # Sizes the copy before anything is created, so the client can confirm with
  # real numbers ("we'll copy 6 boards, 6 of your 12 slots") rather than
  # spending slots the user never agreed to. Shares check_board_create_permissions
  # with #clone, so a user with no room meets the same 422 here — one request
  # earlier than they used to.
  def clone_plan
    set_board
    return if @board.nil? # set_board already rendered 404

    render json: Boards::CloneSetPlanner.new(@board, user: board_limit_user).call
  end

  def clone
    set_board
    return if @board.nil? # set_board already rendered 404

    new_name = params[:name].presence || @board.name

    # A copy takes the board AND the pages its folder tiles open — one slot per
    # board — because a copied set whose tiles opened the SOURCE owner's live
    # boards was shared state, and flattening them all instead left the user
    # rebuilding pages that already exist. When the set doesn't fit the user's
    # remaining slots we copy what fits, breadth-first, and flatten only the
    # tiles whose targets were left behind. `boards_created`, `boards_in_set`
    # and `limited_by` are how the client says which of those happened;
    # `flattened_tiles` predates them and keeps its meaning.
    plan = Boards::CloneSetPlanner.new(@board, user: board_limit_user).call

    # `include_linked_boards: false` is the user choosing the ROOT ONLY — a set
    # they have room for is still a set they may not want, and spending nine
    # slots to get one board is not a decision to make on their behalf. It caps
    # the copy at one board and clears `limited_by`: nothing was withheld, so
    # there is nothing to offer an upgrade for. Absent or true copies the set.
    root_only = params[:include_linked_boards].to_s == "false"
    boards_to_create = root_only ? 1 : plan.boards_to_create

    cloner = Boards::SetCloner.new(
      @board,
      owner: current_user,
      communicator: nil,
      name: new_name,
      max_depth: Boards::CloneSetPlanner.depth_cap,
      max_boards: boards_to_create,
      out_of_set: :flatten,
      prefix_sub_names: true,
    )

    begin
      @new_board = cloner.call
    rescue Boards::SetCloner::CloneError => e
      Rails.logger.error "[BoardsController#clone] #{e.message}"
      render json: { error: "Failed to copy board" }, status: :unprocessable_content
      return
    end

    if current_user.vendor_id.present?
      @new_board.update(vendor_id: current_user.vendor_id)
    end

    render json: @new_board.api_view_with_images(current_user).merge(
      flattened_tiles: cloner.tiles_flattened,
      boards_created: cloner.boards_created,
      boards_in_set: plan.boards_in_set,
      limited_by: root_only ? nil : plan.limited_by,
    )
  end

  def create_board_group
    set_board
    return if @board.nil? # set_board already rendered 404

    unless @board.user_id == current_user.id || current_user.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    creator = Boards::BoardGroupCreator.new(board: @board, user: current_user)
    board_group = creator.call
    status = creator.created? ? :created : :ok
    # api_view_with_boards omits root_board_id (unlike its sibling api_view) —
    # merge it in so callers can identify the root board without a second call.
    view = board_group.api_view_with_boards(current_user).merge(root_board_id: board_group.root_board_id)
    render json: view, status: status
  end

  def create_from_template
    obf_data = params[:data]
    user_id = current_user.id
    json_data = JSON.parse(obf_data)
    @board = Board.create_from_obf(json_data, user_id)
    render json: @board.api_view_with_images(current_user)
  end

  # Reasons a cover can't be built, phrased for the person who clicked the
  # button. 422 rather than 403/402: nothing here is a permission or credit
  # gate, it's a request that this board can't satisfy.
  PREVIEW_BLOCKER_MESSAGES = {
    "board_has_no_tiles" => "Add a tile to this board first, then build a cover from it.",
  }.freeze

  def generate_preview_image
    set_board
    return if @board.nil? # set_board already rendered 404

    # Refuse synchronously what the job would only skip. Enqueuing here would
    # answer "ok" and leave the client polling for a snapshot that is never
    # coming.
    if (blocker = @board.preview_generation_blocker)
      render json: {
        error: PREVIEW_BLOCKER_MESSAGES.fetch(blocker, "This board can't build a cover from its tiles."),
        code: blocker,
      }, status: :unprocessable_content
      return
    end

    # force: this request names one board, so it renders even for a page the
    # bulk enqueue paths deliberately skip.
    @board.run_generate_preview_job(force: true)
    render json: {
      status: "queued",
      preview_status: @board.preview_status,
      preview_generated_at: @board.preview_generated_at,
    }
  end

  # Designate this board as the user's editable board. On a downgraded (free)
  # plan, all other owned boards become read-only; this lets the user choose
  # which one keeps full edit access. Subject to a cooldown
  # (User::EDITABLE_BOARD_SWITCH_COOLDOWN_DAYS) so a user can't rotate the
  # slot to edit every board one at a time.
  def make_editable
    return if @board.nil?

    unless @board.user_id == current_user.id
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    # No-op when the user re-picks the board that's already designated. Skip
    # the cooldown check so a confirm/double-tap doesn't accidentally start
    # the clock either. Still verify the board really is editable — a
    # designation the slot rules can't honor must not answer 200.
    if current_user.editable_board_id == @board.id
      fresh_user = User.find(current_user.id)
      return render_editable_board_unavailable unless fresh_user.board_editable?(@board)

      render json: { user: fresh_user.api_view, board: @board.api_view(fresh_user) }
      return
    end

    if !current_user.admin? && current_user.editable_board_switch_cooldown_active?
      render json: {
        error: "editable_board_cooldown",
        message: "You can switch your editable board again on #{current_user.editable_board_switch_available_at.to_date.iso8601}.",
        available_at: current_user.editable_board_switch_available_at,
        cooldown_days: User::EDITABLE_BOARD_SWITCH_COOLDOWN_DAYS,
      }, status: :forbidden
      return
    end

    previous_board_id = current_user.editable_board_id
    previous_set_at = current_user.editable_board_id_set_at

    current_user.update!(
      editable_board_id: @board.id,
      editable_board_id_set_at: Time.current,
    )
    fresh_user = User.find(current_user.id)

    # Verify the postcondition instead of assuming it. Writing
    # editable_board_id is not the same as the board becoming editable —
    # User#board_editable? resolves the slot through its own rules, and a pick
    # it can't honor used to leave this endpoint answering 200 with the board
    # still locked. The frontend read that as success, reloaded, and showed the
    # same read-only board: no change, no error, nothing in the UI. Roll the
    # write back and say so instead.
    unless fresh_user.board_editable?(@board)
      current_user.update_columns(
        editable_board_id: previous_board_id,
        editable_board_id_set_at: previous_set_at,
      )
      return render_editable_board_unavailable
    end

    render json: { user: fresh_user.api_view, board: @board.api_view(fresh_user) }
  end

  def pdf
    bw_requested = ActiveModel::Type::Boolean.new.cast(params[:bw])
    qr_param = params[:qr]
    qr_requested = qr_param.nil? ? true : ActiveModel::Type::Boolean.new.cast(qr_param)
    @bw = bw_requested

    render_data = Boards::RenderAssetData.new(
      board: @board,
      screen_size: params[:screen_size] || "lg",
      hide_colors: bw_requested || params[:hide_colors] == "1",
      hide_header: params[:hide_header] == "1",
      routes: Rails.application.routes.url_helpers,
      include_qr: qr_requested,
    ).call

    render_data.each do |key, value|
      instance_variable_set("@#{key}", value)
    end

    html = render_to_string(
      template: "api/boards/print",
      layout: "pdf",
      formats: [:html],
    )

    disp = params[:preview].present? ? "inline" : "attachment"
    response.headers["Cache-Control"] = "no-store"

    grover_options = {
      format: "Letter",
      landscape: @landscape,
      viewport: {
        width: @landscape ? 792 : 612,
        height: @landscape ? 612 : 792,
      },
      full_page: false,
      prefer_css_page_size: true,
      print_background: true,
    }

    file_data = Grover.new(html, **grover_options).to_pdf

    default_variant = !bw_requested && qr_requested
    if default_variant && !@board.pdf_file.attached?
      @board.pdf_file.attach(
        io: StringIO.new(file_data),
        filename: "#{@board.slug}-board.pdf",
        content_type: "application/pdf",
      )
    end

    filename_suffix = bw_requested ? "-bw" : ""
    send_data file_data,
      filename: "#{@board.slug}-board#{filename_suffix}.pdf",
      type: "application/pdf",
      disposition: disp
  end

  private

  # The exclusion list arrives as an Array from a JSON caller and as a
  # comma-joined String from the board editor (see getWords in the frontend's
  # data/boards.ts). Matching only the Array shape silently dropped it for every
  # board-less request, so those suggestions could repeat words already staged.
  def parse_words_to_exclude(raw)
    list = case raw
           when Array then raw
           when String then raw.split(",")
           else []
           end
    list.map { |word| word.to_s.strip }.reject(&:blank?)
  end

  def apply_filter(scope, filter)
    return scope unless filter.present?
    if filter == "public_boards"
      return Board.public_boards # <-- remove .alphabetical
    end
    scope.public_send(filter)
  end

  def public_boards_etag(scope, last_modified)
    [
      "public-boards-v2",
      last_modified.to_i,
      scope.maximum(:id),
      scope.count,
    ]
  end

  def boards_list_last_modified(user, scope)
    scope.maximum(:updated_at) || user.updated_at || Time.zone.at(0)
  end

  def boards_list_etag(user, scope, last_modified)
    [
      "boards-list-v1",
      user.id,
      last_modified.to_i,
      scope.maximum(:id),
      scope.count,
    ]
  end

  def guest_boards_index_etag(last_modified, limit_param, tags: [])
    [
      "guest-boards-index-v2",
      last_modified&.to_i,
      limit_param,
      Array(tags).sort.join("|"),
    ]
  end

  def boards_index_last_modified(user, base_scope)
    # If you want to be extra strict, you could also consider BoardImage etc here.
    base_scope.maximum(:updated_at) || user.updated_at || Time.zone.at(0)
  end

  # Usage numbers for the boards page, off the UNPAGINATED base scope, so the
  # header can read "N of LIMIT" against the same set it is listing.
  def boards_index_counts(user, base_scope)
    countable = base_scope.count
    main = base_scope.main_boards.count
    {
      countable: countable,
      main: main,
      pages: countable - main,
      limit: user.board_limit,
      remaining: [user.board_limit - countable, 0].max,
    }
  end

  def boards_index_etag(user, per_page, base_scope, last_modified, filter:, sort_field:, sort_order:, page:, tags: [])
    [
      "user-boards-index-v3",
      user.id,
      filter || "no-filter",
      sort_field,
      sort_order,
      page,
      per_page,
      Array(tags).sort.join("|"),
      last_modified.to_i,
      base_scope.maximum(:id),
      base_scope.count,
    ]
  end

  def find_board_for_predictive_page
    key = params[:slug].presence || params[:id].presence

    Board.find_by(id: key) ||
      Board.find_by(slug: key) ||
      Board.predictive_default(current_user)
  end

  def board_predictive_last_modified(board)
    # uses MAX(updated_at) across the stuff that affects this JSON
    BoardImage
      .where(board_id: board.id)
      .joins(:image)
      .left_joins(image: :docs)
      .maximum("GREATEST(board_images.updated_at, images.updated_at, COALESCE(docs.updated_at, '1970-01-01'))") ||
      board.updated_at
  end

  def board_predictive_etag(board, user)
    # include user role/settings if that changes output
    [
      "predictive-board",
      board.id,
      board.updated_at.to_i,
      user&.id,
      Digest::MD5.hexdigest((user&.settings || {}).to_json),
    ]
  end

  def broadcast_board_update!
    @board.reload
    @board.broadcast_board_update!
  end

  def qr_data_url_for(url, size: 512, border_modules: 1)
    qr = RQRCode::QRCode.new(url)
    png = qr.as_png(size: size, border_modules: border_modules)
    "data:image/png;base64,#{Base64.strict_encode64(png.to_s)}"
  end

  # The honest answer when a make_editable pick cannot take effect: the write
  # went in but the slot rules didn't honor it, so the board is still
  # read-only. Shaped like the cooldown response (error code + message) so the
  # frontend renders it the same way.
  def render_editable_board_unavailable
    render json: {
      error: "editable_board_not_available",
      message: "This board can't be your editable board. Upgrade to edit every board.",
    }, status: :unprocessable_content
  end

  # Use callbacks to share common setup or constraints between actions.
  def set_board
    key = params[:slug].presence || params[:id].presence
    paramiterized_key = key.to_s.parameterize

    @board = Board.find_by(id: key) ||
             Board.find_by(slug: key)
    @board ||= Board.find_by(slug: paramiterized_key)
    unless @board
      render json: { error: "Board not found" }, status: :not_found
      return
    end
  end

  def check_board_view_edit_permissions
    set_board
    unless @board.user == current_user || current_user.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
  end

  # Boards over a downgraded user's plan limit are read-only: still fully
  # usable (view/tap/audio) but not editable. Blocks content-mutating actions
  # on a locked board with HTTP 403 (402 is reserved for credit exhaustion).
  def check_board_editable!
    set_board if @board.nil?
    return if @board.nil? # set_board already rendered 404

    # `acting_user`, not `current_user`: #add_image reaches here on a
    # communicator token, where current_user is nil. The plan limit belongs to
    # the adult who owns the account either way, and reading `current_user`
    # here raised NoMethodError building the body below.
    user = acting_user
    return if user&.board_editable?(@board)

    # No resolvable user means there is no plan to measure against — refuse
    # rather than fall through to a body full of nils.
    unless user
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    render json: {
      error: "board_locked",
      message: "This board is read-only on your current plan. Upgrade, or make it your editable board, to make changes.",
      board_limit: user.board_limit,
      editable_board_id: user.effective_editable_board_id,
    }, status: :forbidden
  end

  # A communicator may only add a tile to a board that is actually on their own
  # dashboard.
  #
  # This is NOT redundant with check_board_editable!: `User#board_editable?`
  # returns true for a board you do not own (`board.user_id != id` short-
  # circuits it), so it is a PLAN lock, not an ownership check. Without this a
  # communicator token could write a tile onto any board id in the system.
  # Ordinary user tokens are untouched — they keep exactly the gates they had.
  def check_communicator_board_access!
    return if current_user # a user token answers to the existing gates

    # authenticate_signed_in! guarantees one of the two credentials exists, so
    # reaching here means a communicator token.
    unless acting_user
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    set_board if @board.nil?
    return if @board.nil? # set_board already rendered 404
    return if current_account.boards.exists?(id: @board.id)

    render json: {
      error: "board_not_available",
      message: "This board isn't on your dashboard.",
    }, status: :forbidden
  end

  # ---- Marketplace protection -------------------------------------------
  #
  # A board whose content was sold as a printable is frozen: printed sheets
  # carry a QR pointing at /pb/<slug> and paper can't be re-issued. Deleting,
  # unpublishing and renaming are refused outright (released only by an admin
  # waiver on the printable); structural tile edits are refused once and then
  # allowed with an explicit confirm.
  #
  # All of these are 409 — a state conflict on the resource, the same code the
  # existing board_in_use / publish_cascade warnings use. Never 403, which is
  # reserved for permission and plan gates.

  # Renders and returns true when the board itself is protected.
  def render_marketplace_protection_conflict(board, action:, blocked_action: nil)
    protection = board.marketplace_protection
    return false unless protection.protected?

    noun = protection.role == :root ? "board" : "page"
    render json: {
      error: "board_marketplace_protected",
      message: "\"#{board.name}\" is #{protection.role == :root ? "sold as a printable" : "part of a printable that's for sale"} — printed copies point at this #{noun}, so it can't be #{action}. Release protection on the printable in the admin first.",
      board: { id: board.id, name: board.name },
      blocked_action: blocked_action || action,
      marketplace: protection.summary,
    }, status: :conflict
    true
  end

  # Renders and returns true when a cascade would take a protected board with
  # it. The cascade is refused whole — never partially applied.
  def render_marketplace_cascade_conflict(blocked_ids, key:)
    return false if blocked_ids.blank?

    boards = Board.where(id: blocked_ids.to_a).pluck(:id, :name).map { |id, name| { id: id, name: name } }
    render json: {
      error: "board_marketplace_protected",
      message: "Deleting \"#{@board.name}\" would also delete #{boards.size == 1 ? "a board" : "#{boards.size} boards"} sold as a printable. Release protection in the admin first.",
      board: { id: @board.id, name: @board.name },
      blocked_action: "deleted",
      key => boards,
    }, status: :conflict
    true
  end

  def render_marketplace_cascade_conflict_for_unpublish(blocked_ids)
    return false if blocked_ids.blank?

    boards = Board.where(id: blocked_ids.to_a).pluck(:id, :name).map { |id, name| { id: id, name: name } }
    render json: {
      error: "board_marketplace_protected",
      message: "Unpublishing \"#{@board.name}\" would take #{boards.size == 1 ? "a page" : "#{boards.size} pages"} sold as a printable offline. Release protection in the admin first.",
      board: { id: @board.id, name: @board.name },
      blocked_action: "unpublish",
      blocked_boards: boards,
    }, status: :conflict
    true
  end

  # Structural tile edits: warn once, then proceed on confirm_marketplace_edit.
  # Deliberately NOT `confirm`, which #update already means "yes, cascade the
  # publish" by — reusing it would let one click authorize the other thing.
  def check_marketplace_edit_confirmed!
    set_board if @board.nil?
    return if @board.nil?
    return unless marketplace_edit_is_structural?
    return if params[:confirm_marketplace_edit].to_s == "true"

    protection = @board.marketplace_protection
    return unless protection.protected?

    render json: {
      error: "board_marketplace_edit_confirmation_required",
      message: "\"#{@board.name}\" is sold as a printable. Changing it means the paper a buyer holds and the board online stop matching.",
      board: { id: @board.id, name: @board.name },
      marketplace: protection.summary,
    }, status: :conflict
  end

  # Every gated action except #update is structural by definition. #update is
  # the general-purpose save, so it only counts when the payload actually
  # touches structure — a favorite/tags/category save shouldn't prompt.
  #
  # Reads raw params rather than `board_params`, which calls
  # `params.require(:board)` and would raise on the image_ids_to_remove-only
  # payload (itself a structural edit: it removes tiles).
  # `name` is deliberately absent: renaming is refused outright inside #update,
  # and listing it here would let the softer before_action answer first — a
  # confirmable 409 in front of an unconfirmable one, which is the ordering
  # this feature avoids everywhere else. It would also fire on the ordinary
  # save that re-sends the board's existing name unchanged.
  MARKETPLACE_STRUCTURAL_KEYS = %w[
    number_of_columns small_screen_columns medium_screen_columns
    large_screen_columns word_list layout
  ].freeze

  # Same shape as the publish-cascade guard: raw booleans only, so a malformed
  # value can't read as "unpublish".
  def unpublishing_requested?
    return false if params[:image_ids_to_remove].present?
    return false unless params[:board].respond_to?(:key?) && params[:board].key?("published")

    target = ActiveModel::Type::Boolean.new.cast(params[:board]["published"])
    target == false && @board.published?
  end

  def renaming_requested?
    return false if params[:image_ids_to_remove].present?

    incoming = params.dig(:board, :name)
    incoming.present? && incoming.to_s != @board.name.to_s
  end

  def marketplace_edit_is_structural?
    return true unless action_name == "update"
    return true if params[:image_ids_to_remove].present?

    board_payload = params[:board]
    return false if board_payload.blank?

    MARKETPLACE_STRUCTURAL_KEYS.any? { |key| board_payload.key?(key) }
  end

  def boards_for_user
    Board.for_user(current_user)
  end

  def image_params
    # :user_id is intentionally NOT permitted on the nested docs — the doc owner
    # is assigned server-side (new_doc.user = current_user in #add_image), so a
    # client can't set or reassign ownership via mass-assignment (#27).
    params.require(:image).permit(:label, :image_prompt, :display_image, :part_of_speech, audio_files: [], docs: [:id, :image, :documentable_id, :documentable_type, :processed, :_destroy])
  end

  # Optional gestalt tile metadata for add_image (Script Collector). Free-form
  # strings stored on board_images.data; returns {} when absent so the merge is
  # a no-op for non-gestalt tiles.
  def gestalt_metadata
    return {} if params[:data].blank?

    params.require(:data)
          .permit(:gestalt_source, :utterance_function)
          .to_h
          .reject { |_k, v| v.blank? }
  end

  # A board the caller may point a tile at: one of their own, or one from the
  # public library. Deliberately mirrors what the frontend's board picker
  # offers (GET boards/list + GET public_boards) and the IDOR scoping in
  # #associate_image. An id outside that set resolves to nil and is ignored —
  # the tile is still created, just unlinked — rather than 404ing a request
  # whose main job (add a tile) succeeded.
  def linkable_board(id)
    # acting_user: only reached from #add_image, which a communicator token can
    # now make. A communicator links against their owning user's boards.
    return nil unless acting_user
    return Board.find_by(id: id) if acting_user.admin?

    acting_user.boards.find_by(id: id) || Board.public_boards.find_by(id: id)
  end

  # Optional communicator-profile fields passed by the frontend's
  # "Who is this board for?" picker. Returns a plain hash so it stays
  # JSON-serializable for Sidekiq job args (strict_args rejects
  # HashWithIndifferentAccess, which is what `to_h` alone returns).
  # All fields are optional.
  def communicator_profile_params
    params.permit(:age, :age_band, :aac_level, :vocab_type).to_h.to_hash
  end

  # Optional communicator for profile-aware AI calls. Scoped to the caller's
  # own communicator_accounts — an id belonging to another user resolves to
  # nil (ignored), never a bare ChildAccount.find.
  def profile_communicator
    return nil if params[:communicator_id].blank?

    current_user.communicator_accounts.find_by(id: params[:communicator_id])
  end

  # Only allow a list of trusted parameters through.
  def board_params
    permitted = params.require(:board).permit(:name,
                                  :slug,
                                  :regenerate_slug,
                                  :text_color,
                                  :bg_color,
                                  :parent_id,
                                  :parent_type,
                                  :description,
                                  :predefined,
                                  :favorite,
                                  :published,
                                  :number_of_columns,
                                  :preset_display_image,
                                  :voice,
                                  :language,
                                  :small_screen_columns,
                                  :medium_screen_columns,
                                  :large_screen_columns,
                                  :next_words,
                                  :images,
                                  :layout,
                                  :image_ids,
                                  :image_id,
                                  :query,
                                  :page,
                                  :display_image_url, :category, :image_ids_to_remove, :board_type, settings: {}, margin_settings: {}, tags: [])
    # `predefined` is curation and stays admin-only: it decides whether a board
    # is offered as a starter board, and `Board.public_boards` (the curated
    # gallery) is `admin-owned AND predefined AND published`. Stripping
    # `predefined` is what stops a regular user self-promoting into that
    # gallery (#27, mirrors the board_groups_controller pattern).
    #
    # `published` is NOT curation — on a user-owned board it only decides
    # whether `Board#viewable_by?` lets a logged-out visitor open the board's
    # own /pb/<slug> link, which is how a user's Public page and MySpeak tiles
    # reach their boards. Owners need it, and stripping it here made the UI's
    # Publish toggle a silent no-op (#633, frontend). It is safe to permit for
    # non-admins because `update` is already gated to the owner
    # (check_board_view_edit_permissions + User#can_edit?, which also refuses
    # any predefined board), so the only non-admin who can set it is the person
    # who owns the board.
    #
    # `slug` IS curation in the same sense: it is the `/pb/<slug>` key that
    # shared links, MySpeak tiles and printed QR codes resolve through. It is
    # issued from the name once at creation and then belongs to the URL, not to
    # the name — owners rename their boards freely, but re-keying a live URL is
    # an admin act. `regenerate_slug` is the opt-in that asks for a re-derive,
    # so it is gated the same way. Stripping both is what makes an ordinary
    # rename a no-op on the slug (see #update).
    permitted.delete(:predefined) unless current_user&.admin?
    unless current_user&.admin?
      permitted.delete(:slug)
      permitted.delete(:regenerate_slug)
    end
    permitted
  end

  def attach_image_to_board(image_data, file_extension)
    throw "No image data provided" unless image_data
    preset_display_img = @board.preset_display_image.attach(io: image_data, filename: "preset_display_image.#{file_extension}", content_type: image_data.content_type)
    @board.save!

    preset_display_image_url = @board.display_preset_image_url
    @board.update_preset_display_image_url(preset_display_image_url)
    @board.write_attribute(:display_image_url, preset_display_image_url)
    # An uploaded cover is a deliberate pick — flip the switch to custom so the
    # getter serves it instead of the auto preview.
    @board.settings = (@board.settings || {}).merge("display_image_source" => "custom")
    @board.save!
  end

  def save_layout!
    if !@board || params[:layout].blank?
      Rails.logger.error "Cannot save layout: Board not found or layout parameter is blank"
      return
    end
    layout_items = (@layout ||= params[:layout].map(&:to_unsafe_h))
    @board.apply_layout!(
      layout: layout_items,
      screen_size: params[:screen_size] || "lg",
      columns: {
        small_screen_columns: params[:small_screen_columns],
        medium_screen_columns: params[:medium_screen_columns],
        large_screen_columns: params[:large_screen_columns],
      },
      margins: { x: params[:xMargin], y: params[:yMargin] },
      settings: params[:settings],
    )
  end
end
