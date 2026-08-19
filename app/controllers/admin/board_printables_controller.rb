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
      # One query for the whole picker. The partial takes this as a local; a
      # per-row `board.marketplace_protected?` would be PUBLIC_BOARD_LIMIT
      # queries.
      @protected_board_ids = Boards::MarketplaceProtection.protected_board_ids(
        (@public_boards + @boards).map(&:id),
      )
    end

    def show
      @printable = BoardPrintable.find(params[:id])
      @listing = @printable.listing_copy_or_default
      @marketplace_copy = Printables::MarketplaceCopy.new(@printable, listing: @listing)
      @tree_boards = tree_boards(@printable)
      @tag_overlap = Etsy::TagOverlap.new(@printable, tags: @listing["tags"])
      @etsy_configured = Etsy::Client.configured?
      # The listing-video card offers a render button only where the binaries
      # exist; a button that enqueues a job which immediately returns looks
      # broken rather than unsupported.
      @ffmpeg_available = VideoTranscoder.available?
    end

    # Saves the editable listing copy. Deliberately separate from publishing:
    # the copy is reviewed and edited first, and saving it must never touch
    # Etsy.
    def update_listing
      printable = BoardPrintable.find(params[:id])

      # `topic` is a column, not part of the listing_copy jsonb, but it is
      # edited on the same form because it is the input that DRIVES that copy.
      # Saving it does not rewrite the copy — that is the separate, confirmed
      # regenerate below, since rebuilding would discard hand edits.
      printable.update!(
        listing_copy: listing_copy_params(printable),
        topic: params[:topic].presence,
      )
      redirect_to admin_dashboard_board_printable_path(printable), notice: "Listing copy saved."
    end

    # Re-runs Etsy::ListingCopy over the record, which is the only way a topic
    # set after creation can reach the copy — the generator is deterministic, so
    # nothing else re-reads it. Destructive to hand-edited title/summary/
    # description/tags, which is what the confirm dialog is for.
    #
    # Local only: this touches no marketplace. A published printable's live
    # listing is unaffected until the copy is pushed with the printables CLI.
    def regenerate_listing_copy
      printable = BoardPrintable.find(params[:id])

      printable.regenerate_listing_copy!
      redirect_to admin_dashboard_board_printable_path(printable),
                  notice: "Listing copy regenerated from the topic. Nothing has been sent to Etsy."
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

    # Sends an already-rendered video to the listing this printable is attached
    # to. The one listing mutation this app performs after creation, and it is
    # additive: Etsy allows one video per listing, none of these listings has
    # one, and a POST adds it. No state, no delete, no update call — the
    # drafts-only invariant is untouched. See Etsy::PushListingVideo.
    def push_video_to_etsy
      printable = BoardPrintable.find(params[:id])

      if !printable.etsy_published?
        redirect_to admin_dashboard_board_printable_path(printable),
                    alert: "This printable isn't attached to an Etsy listing, so there's nothing to send a video to."
      elsif !printable.listing_video?
        redirect_to admin_dashboard_board_printable_path(printable),
                    alert: "There's no listing video yet. Render or upload one first."
      elsif printable.etsy_video_pushed?
        redirect_to admin_dashboard_board_printable_path(printable),
                    alert: "A video has already been sent to listing #{printable.etsy_listing_id}. Etsy allows " \
                           "one per listing and this app can't replace it — swap it in the Etsy seller UI."
      elsif !Etsy::Client.configured?
        redirect_to admin_dashboard_board_printable_path(printable),
                    alert: "Etsy isn't configured. Set the ETSY_* env vars and run `rake etsy:seed_refresh_token`."
      else
        PushBoardPrintableVideoToEtsyJob.perform_async(printable.id)
        redirect_to admin_dashboard_board_printable_path(printable),
                    notice: "Sending the video to listing #{printable.etsy_listing_id}… refresh in a moment."
      end
    end

    # Detaches this printable from its Etsy draft so Publish can create a fresh
    # one. The only way a re-rendered gallery reaches Etsy at all: this app
    # CREATES listings and has no call that updates one, by design, so an
    # existing draft can never be brought up to date in place.
    #
    # Deliberately does not touch Etsy. The old draft stays there until an
    # operator deletes it, because deleting it from here would mean adding the
    # delete call the drafts-only invariant exists to keep out.
    def relist_on_etsy
      printable = BoardPrintable.find(params[:id])

      if !printable.etsy_published?
        redirect_to admin_dashboard_board_printable_path(printable),
                    alert: "This printable isn't attached to an Etsy listing, so there's nothing to relist."
      else
        previous = printable.etsy_listing_id
        printable.relist!
        redirect_to admin_dashboard_board_printable_path(printable),
                    notice: "Detached from Etsy listing #{previous}. Delete that draft on Etsy, then publish " \
                            "again to create a new one. The boards it protects stay protected."
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

    # Releases the boards this printable froze (Boards::MarketplaceProtection).
    #
    # The only supported way to unprotect a board: it's deliberate, it's
    # attributable, and it leaves the listing pointer alone so the record still
    # says which Etsy draft this was. Not reversible through the UI on purpose —
    # re-protecting is publishing again.
    def waive_protection
      printable = BoardPrintable.find(params[:id])

      # `ever_published`, not `published`: a relisted printable has no listing id
      # while its boards are still frozen, and the waiver has to stay reachable.
      if !printable.etsy_ever_published?
        redirect_to admin_dashboard_board_printable_path(printable),
                    alert: "This printable was never published to Etsy, so it isn't protecting anything."
      elsif printable.protection_waived?
        redirect_to admin_dashboard_board_printable_path(printable),
                    alert: "Protection was already released #{printable.protection_waived_at.to_date}."
      else
        printable.waive_protection!(user: current_user, reason: params[:reason])
        redirect_to admin_dashboard_board_printable_path(printable),
                    notice: "Protection released. These boards can be edited, renamed and deleted again — printed copies still point at them."
      end
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

    def regenerate_listing_video
      printable = BoardPrintable.find(params[:id])

      if !printable.complete?
        redirect_to admin_dashboard_board_printable_path(printable),
                    alert: "This printable isn't finished generating yet."
      elsif !VideoTranscoder.available?
        # Said out loud rather than enqueued: the job would return immediately
        # and the page would look like the button did nothing.
        redirect_to admin_dashboard_board_printable_path(printable),
                    alert: "ffmpeg isn't installed on this host, so a listing video can't be rendered here."
      else
        RenderBoardPrintableListingVideoJob.perform_async(printable.id)
        redirect_to admin_dashboard_board_printable_path(printable),
                    notice: "Rendering the listing video… this takes a minute or two. Refresh to see it."
      end
    end

    # A hand-made clip, for the listings worth filming. The rendered
    # flip-through is a good default for every listing; a real recording of a
    # board being used is better than a default, and there is no renderer that
    # can produce one.
    #
    # Validated here rather than trusted: Etsy accepts an out-of-spec video on
    # upload and only rejects it when the seller tries to ACTIVATE the listing,
    # by which point nothing points back at the cause.
    def upload_listing_video
      printable = BoardPrintable.find(params[:id])
      upload = params[:video]

      error = manual_video_error(upload)
      if error
        redirect_to admin_dashboard_board_printable_path(printable), alert: error
        return
      end

      # Probed BEFORE the bytes are read: probing consumes the upload and
      # rewinds it, so reading first leaves ffprobe an empty file and the
      # length check silently passes on every clip.
      duration = VideoTranscoder.available? ? probe_upload_duration(upload) : nil
      bytes = upload.read

      if duration && (duration < BoardPrintable::VIDEO_MIN_SECONDS || duration > BoardPrintable::VIDEO_MAX_SECONDS)
        redirect_to admin_dashboard_board_printable_path(printable),
                    alert: "Etsy needs a listing video between #{BoardPrintable::VIDEO_MIN_SECONDS.to_i} and " \
                           "#{BoardPrintable::VIDEO_MAX_SECONDS.to_i} seconds; this one is #{duration.round(1)}s."
        return
      end

      printable.attach_video!(
        bytes: bytes,
        duration: duration || 0,
        source: BoardPrintable::VIDEO_MANUAL,
      )

      redirect_to admin_dashboard_board_printable_path(printable),
                  notice: "Uploaded. This clip will go up with the draft instead of a rendered flip-through."
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

    # mp4 only. Not a taste preference: the rendered flip-through is H.264 mp4,
    # Etsy processes that most reliably, and accepting anything else would mean
    # owning a transcode path for operator uploads too.
    MANUAL_VIDEO_CONTENT_TYPES = ["video/mp4"].freeze

    def manual_video_error(upload)
      return "Choose a video file to upload." if upload.blank? || !upload.respond_to?(:read)
      unless MANUAL_VIDEO_CONTENT_TYPES.include?(upload.content_type)
        return "That file is #{upload.content_type.presence || 'an unknown type'}; upload an .mp4."
      end
      if upload.size > Etsy::Client::VIDEO_CAP_BYTES
        return "That clip is #{ActiveSupport::NumberHelper.number_to_human_size(upload.size)}; " \
               "Etsy caps a listing video at 100 MB."
      end

      nil
    end

    # ffprobe needs a path, and an uploaded file may be in memory. Returns nil
    # rather than raising: an unreadable duration is a reason to skip the
    # length CHECK, not a reason to refuse a clip the operator chose.
    def probe_upload_duration(upload)
      Dir.mktmpdir("manual-listing-video") do |dir|
        path = File.join(dir, "upload.mp4")
        File.binwrite(path, upload.read)
        upload.rewind
        VideoTranscoder.duration(path)
      end
    rescue StandardError => e
      Rails.logger.warn("[Admin::BoardPrintables] could not probe uploaded video: #{e.class}: #{e.message}")
      nil
    end

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

    # The boards worth offering a one-click printable for: every admin-owned
    # published board, not just the curated catalogue (`predefined: true`).
    # This is deliberately wider than `Board.public_boards` — it also picks up
    # Board Builder roots and any other admin-owned board that was published
    # without ever being flagged predefined (see Boards::AdminBuilder::Build#new_board).
    #
    # Builder CHILD pages are excluded (via `Board.admin_owned_boards`): a
    # printable walks the tree from its root, so listing every folder page as
    # its own row would bury the board they belong to. They're still
    # reachable through the search box below.
    def printable_boards
      @printable_boards ||= Board.admin_owned_boards
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
