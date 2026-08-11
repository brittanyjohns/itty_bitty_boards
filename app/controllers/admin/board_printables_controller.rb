module Admin
  class BoardPrintablesController < Admin::ApplicationController
    PUBLIC_BOARD_LIMIT = 100
    SORTABLE_BOARD_COLUMNS = %w[name subboards created_at updated_at].freeze

    # Directly linked subboards, as a scalar subquery, so "sort by subboards"
    # happens in the database. Sorting the fetched page in Ruby would only
    # order the first PUBLIC_BOARD_LIMIT rows the *name* sort happened to
    # return, which is a different (and wrong) answer.
    SUBBOARD_COUNT_SQL = <<~SQL.squish.freeze
      (SELECT COUNT(DISTINCT bi.predictive_board_id)
         FROM board_images bi
        WHERE bi.board_id = boards.id
          AND bi.predictive_board_id IS NOT NULL
          AND bi.predictive_board_id <> bi.board_id)
    SQL

    def index
      @printables = BoardPrintable.includes(:board).recent.limit(50)
      @board_sort = params[:sort].presence_in(SORTABLE_BOARD_COLUMNS) || "name"
      @board_dir = params[:dir].presence_in(%w[asc desc]) || "asc"

      @board_search = params[:board_search]
      @boards = if @board_search.present?
        sorted_boards(Board.where("name ILIKE ? OR CAST(id AS TEXT) = ?", "%#{@board_search}%", @board_search)).limit(25)
      else
        []
      end

      @public_boards_count = printable_boards.count
      @public_boards = sorted_boards(printable_boards).limit(PUBLIC_BOARD_LIMIT)

      @subboard_counts = direct_subboard_counts(@public_boards + @boards)
    end

    def show
      @printable = BoardPrintable.find(params[:id])
      @listing = @printable.listing_copy_or_default
      @marketplace_copy = Printables::MarketplaceCopy.new(@printable, listing: @listing)
      @tree_boards = tree_boards(@printable)
      @etsy_configured = Etsy::Client.configured?
    end

    # Saves the editable listing copy. Deliberately separate from publishing:
    # the copy is reviewed and edited first, and saving it must never touch
    # Etsy.
    def update_listing
      printable = BoardPrintable.find(params[:id])

      printable.update!(listing_copy: listing_copy_params(printable))
      redirect_to admin_dashboard_board_printable_path(printable), notice: "Listing copy saved."
    end

    # Enqueues the DRAFT-only Etsy publish. Nothing here can activate a
    # listing — see Etsy::PublishBoardPrintable.
    def publish_to_etsy
      printable = BoardPrintable.find(params[:id])

      if !printable.complete?
        redirect_to admin_dashboard_board_printable_path(printable),
                    alert: "This printable isn't finished generating yet."
      elsif printable.etsy_published?
        redirect_to admin_dashboard_board_printable_path(printable),
                    alert: "Already on Etsy as listing #{printable.etsy_listing_id}."
      elsif !Etsy::Client.configured?
        redirect_to admin_dashboard_board_printable_path(printable),
                    alert: "Etsy isn't configured. Set the ETSY_* env vars and run `rake etsy:seed_refresh_token`."
      else
        # Persist whatever is currently in the form's defaults so the draft and
        # the page agree — publishing what an admin never saw would be worse
        # than making them press Save first.
        printable.update!(listing_copy: printable.listing_copy_or_default) if printable.listing_copy.blank?
        printable.update_columns(etsy_error: nil, updated_at: Time.current)

        PublishBoardPrintableToEtsyJob.perform_async(printable.id)
        redirect_to admin_dashboard_board_printable_path(printable),
                    notice: "Creating the Etsy draft… refresh in a moment to see the result."
      end
    end

    # Re-runs the whole PDF pipeline on the SAME record so the printable picks
    # up board edits. The tree is re-walked (Generate rewrites board_ids), so a
    # subboard added since the first run is included.
    #
    # Listing copy, the Etsy listing id and the gallery images are deliberately
    # left alone: regenerating is about the document, and silently clearing an
    # admin's reviewed copy — or the pointer to a live Etsy draft — would be a
    # far worse surprise than stale marketing images they can re-render with the
    # button that already exists.
    def regenerate
      printable = BoardPrintable.find(params[:id])

      if %w[pending generating].include?(printable.status)
        redirect_to admin_dashboard_board_printable_path(printable),
                    alert: "This printable is already generating."
        return
      end

      printable.update!(status: "pending", error_message: nil)
      GenerateBoardPrintableJob.perform_async(printable.id)

      redirect_to admin_dashboard_board_printable_path(printable),
                  notice: "Regenerating from the current board… the listing images are now out of date, so re-render those when it finishes."
    end

    # Destroys the record and (via Active Storage) its PDFs and gallery images.
    # Nothing is sent to Etsy: an existing draft stays where it is, because this
    # app never mutates a listing's state — see Etsy::Client.
    def destroy
      printable = BoardPrintable.find(params[:id])
      name = printable.board&.name || "Board ##{printable.board_id}"

      printable.destroy!

      redirect_to admin_dashboard_board_printables_path,
                  notice: "Deleted the printable for “#{name}”."
    end

    def regenerate_listing_images
      printable = BoardPrintable.find(params[:id])

      unless printable.complete?
        redirect_to admin_dashboard_board_printable_path(printable),
                    alert: "This printable isn't finished generating yet."
        return
      end

      RenderBoardPrintableListingImagesJob.perform_async(printable.id)
      redirect_to admin_dashboard_board_printable_path(printable),
                  notice: "Rendering listing images… refresh in a moment."
    end

    def create
      board = Board.find_by(id: params[:board_id])
      unless board
        redirect_to admin_dashboard_board_printables_path, alert: "Board not found."
        return
      end

      include_subboards = ActiveModel::Type::Boolean.new.cast(params[:include_subboards]) || false
      max_boards = (params[:max_boards].presence&.to_i || BoardPrintable::DEFAULT_MAX_BOARDS)
        .clamp(1, BoardPrintable::MAX_BOARDS_CEILING)

      board_ids = Boards::Printables::CollectPages.walk_board_tree(
        board: board,
        include_subboards: include_subboards,
        max_boards: max_boards,
      ).map(&:id)

      printable = BoardPrintable.create!(
        board: board,
        created_by: current_user,
        status: "pending",
        include_subboards: include_subboards,
        max_boards: max_boards,
        topic: params[:topic].presence,
        board_ids: board_ids,
      )

      GenerateBoardPrintableJob.perform_async(printable.id)

      redirect_to admin_dashboard_board_printable_path(printable), notice: "Generating printable for \"#{board.name}\"…"
    rescue Boards::Printables::CollectPages::TreeTooLargeError => e
      redirect_to admin_dashboard_board_printables_path, alert: e.message
    end

    private

    # The listing_copy jsonb is written wholesale rather than merged: the form
    # posts every field every time, so a merge would only ever preserve stale
    # keys from an older shape. Anything the form doesn't carry (the TPT
    # overrides) is folded back in explicitly.
    def listing_copy_params(printable)
      tags = params[:tags].to_s.split(",").map(&:strip).reject(&:blank?)
      existing = printable.listing_copy.to_h

      existing.merge(
        "title" => params[:title].to_s.strip,
        "summary" => params[:summary].to_s.strip,
        "description" => params[:description].to_s,
        # Normalized here, not just at publish time, so an admin sees exactly
        # the tags Etsy will receive rather than discovering the drops later.
        "tags" => Etsy::Client.new.normalize_tags(tags),
        "price_cents" => price_cents_param,
      )
    end

    def price_cents_param
      raw = params[:price].to_s.strip
      return Etsy::ListingCopy::DEFAULT_PRICE_CENTS if raw.blank?

      (raw.to_f * 100).round.clamp(20, 100_000)
    end

    # The boards the printable actually walked, back in tree order — a plain
    # `where` returns them in whatever order Postgres likes.
    def tree_boards(printable)
      ids = printable.board_ids.to_a
      return [] if ids.size <= 1

      by_id = Board.where(id: ids).index_by(&:id)
      ids.filter_map { |id| by_id[id] }
    end

    # The boards worth offering a one-click printable for. `public_boards` is
    # the catalogue; Board Builder boards are the other half — published and
    # authored for print, but deliberately not `predefined`, so the catalogue
    # scope can't see them (see Boards::AdminBuilder::Build#new_board).
    #
    # Builder CHILD pages are excluded: a printable walks the tree from its
    # root, so listing every folder page as its own row would bury the board
    # they belong to. They're still reachable through the search box below.
    def printable_boards
      @printable_boards ||= Board.where(id: Board.public_boards.select(:id))
                                 .or(Board.where(id: builder_root_boards.select(:id)))
    end

    def builder_root_boards
      AdminBoardBuild.builder_boards.published.not_builder_child
    end

    # @board_sort / @board_dir are whitelisted above, so they are safe to
    # interpolate. Every sort falls back to name so the order is total —
    # boards created in the same seed run otherwise shuffle between requests.
    def sorted_boards(scope)
      name_order = "LOWER(boards.name) ASC"

      case @board_sort
      when "name"
        scope.reorder(Arel.sql("LOWER(boards.name) #{@board_dir.upcase}"))
      when "subboards"
        scope.reorder(Arel.sql("#{SUBBOARD_COUNT_SQL} #{@board_dir.upcase}, #{name_order}"))
      else
        scope.reorder(Arel.sql("boards.#{@board_sort} #{@board_dir.upcase}, #{name_order}"))
      end
    end

    # Directly linked subboards per board, in one grouped query — the full tree
    # would need a walk per row, and the list can be 100 boards long. Self-links
    # are excluded because the tree walk skips them too.
    def direct_subboard_counts(boards)
      ids = boards.map(&:id).uniq
      return {} if ids.empty?

      # reorder(nil) drops BoardImage's default position ordering — Postgres
      # rejects an ORDER BY column that isn't in the GROUP BY.
      BoardImage
        .reorder(nil)
        .where(board_id: ids)
        .where.not(predictive_board_id: nil)
        .where("predictive_board_id != board_id")
        .group(:board_id)
        .distinct
        .count(:predictive_board_id)
    end
  end
end
