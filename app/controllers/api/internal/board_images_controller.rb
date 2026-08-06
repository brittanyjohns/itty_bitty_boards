class API::Internal::BoardImagesController < API::Internal::ApplicationController
  # AI generation is queued in slices, mirroring
  # `Board#find_or_create_images_from_word_list`, so one 60-tile build doesn't
  # become one 60-image Sidekiq job.
  GENERATE_BATCH_SIZE = 3

  # How many idempotency keys a board remembers. Bounded because they live in
  # the board's `settings` jsonb, which is loaded on every board read.
  IDEMPOTENCY_KEY_HISTORY = 20

  def create
    @board = Board.find(params[:board_id])

    image = resolve_image_from(params)
    return render json: { error: "image_id or label is required" }, status: :unprocessable_content if image.nil?

    board_image = @board.add_image(image.id)

    if board_image&.persisted?
      apply_optional_attributes!(board_image, params)
      pin_authored_label!(board_image, params, image)
      queue_missing_art!(label_path?(params) ? [image.id] : [])
      render json: board_image.api_view(current_user), status: :created
    else
      errors = board_image&.errors&.full_messages&.join(", ") || "Unable to add image to board"
      render json: { error: errors }, status: :unprocessable_content
    end
  end

  def bulk
    @board = Board.find(params[:board_id])

    raw_cells = params[:cells]
    unless raw_cells.is_a?(Array) && raw_cells.any?
      return render json: { error: "cells must be a non-empty array" }, status: :unprocessable_content
    end

    # A retry of a request that already committed replays the original cells
    # instead of creating a second copy of every tile. Without this the
    # documented-atomic endpoint punishes the obvious client behaviour —
    # retry on 5xx — with a silently duplicated board (#574).
    if idempotency_key && (replayed = replayed_cells(idempotency_key))
      response.headers["Idempotent-Replay"] = "true"
      return render json: replayed.map { |bi| cell_view(bi) }, status: :ok
    end

    cells = raw_cells.map { |cell| normalize_cell(cell) }

    created = []
    errors = []
    label_resolved_image_ids = []

    ActiveRecord::Base.transaction do
      @board.board_images.destroy_all if replace?

      # One resolution pass for every distinct label in the request. Resolving
      # per cell cost 2-3 queries per tile, which is most of what pushed a
      # 48-cell request toward the proxy timeout that produced #574.
      resolved = Boards::ImageResolver.resolve_all(
        cells.filter_map { |cp| cp[:label].to_s.strip if label_path?(cp) },
        owner: current_user,
      )

      cells.each_with_index do |cp, index|
        image = resolve_image_from(cp, resolved: resolved)
        if image.nil?
          errors << { index: index, error: "image_id or label is required" }
          next
        end
        label_resolved_image_ids << image.id if label_path?(cp)

        board_image = @board.add_image(image.id)
        unless board_image&.persisted?
          msg = board_image&.errors&.full_messages&.join(", ") || "Unable to add image to board"
          errors << { index: index, error: msg }
          next
        end

        unless apply_optional_attributes!(board_image, cp)
          errors << { index: index, error: board_image.errors.full_messages.join(", ") }
          next
        end

        pin_authored_label!(board_image, cp, image)

        created << board_image
      end

      remember_idempotency_key!(idempotency_key, created) if errors.empty? && idempotency_key

      raise ActiveRecord::Rollback if errors.any?
    end

    if errors.any?
      render json: { errors: errors }, status: :unprocessable_content
    else
      resync_layout! if replace?
      # Only after the transaction has actually committed — a rolled-back bulk
      # must not leave Sidekiq holding ids of Images that no longer exist.
      queue_missing_art!(label_resolved_image_ids)
      render json: created.map { |bi| cell_view(bi) }, status: :created
    end
  end

  # PATCH /api/internal/boards/:board_id/board_images/:id
  #
  # The internal API could create a tile but never correct one (#584), so a
  # wrong symbol, colour or label was permanent from the API's point of view
  # and the only repair path was a human in the editor UI.
  def update
    @board = Board.find(params[:board_id])
    board_image = find_cell(params[:id])
    return render json: { error: "board_image not found" }, status: :not_found if board_image.nil?

    result = apply_cell_update!(board_image, params)
    return render json: { error: result }, status: :unprocessable_content if result.is_a?(String)

    render json: board_image.reload.api_view(current_user)
  end

  # PATCH /api/internal/boards/:board_id/board_images/bulk_update
  #
  # Atomic multi-cell edit — the repair counterpart to `bulk`, so a whole
  # board's colours or voice can be corrected in one call.
  def bulk_update
    @board = Board.find(params[:board_id])

    raw_cells = params[:cells]
    unless raw_cells.is_a?(Array) && raw_cells.any?
      return render json: { error: "cells must be a non-empty array" }, status: :unprocessable_content
    end

    updated = []
    errors = []

    ActiveRecord::Base.transaction do
      raw_cells.map { |cell| normalize_cell(cell) }.each_with_index do |cp, index|
        board_image = cp[:id].present? ? find_cell(cp[:id]) : nil
        if board_image.nil?
          errors << { index: index, error: "board_image not found on this board" }
          next
        end

        result = apply_cell_update!(board_image, cp)
        if result.is_a?(String)
          errors << { index: index, error: result }
          next
        end

        updated << board_image
      end

      raise ActiveRecord::Rollback if errors.any?
    end

    if errors.any?
      render json: { errors: errors }, status: :unprocessable_content
    else
      render json: updated.map { |bi| cell_view(bi.reload) }
    end
  end

  # DELETE /api/internal/boards/:board_id/board_images/:id
  def destroy
    @board = Board.find(params[:board_id])
    board_image = find_cell(params[:id])
    return render json: { error: "board_image not found" }, status: :not_found if board_image.nil?

    board_image.destroy
    resync_layout!

    render json: { id: board_image.id, deleted: true, board_images_count: @board.reload.board_images.count }
  end

  private

  # ActionController::Parameters in nested arrays come through as
  # ActionController::Parameters instances; coerce to a hash with indifferent
  # access so the shared attribute helpers work the same way as in #create.
  def normalize_cell(cell)
    if cell.respond_to?(:permit!)
      cell.permit!.to_h.with_indifferent_access
    else
      cell.to_h.with_indifferent_access
    end
  end

  def find_cell(id)
    @board.board_images.find_by(id: id)
  end

  # An explicit `image_id` pins that exact record; a bare `label` goes through
  # label resolution (and is the only path that may create an Image or spend an
  # OpenAI call).
  def label_path?(p)
    p[:image_id].blank? && p[:label].present?
  end

  # `Boards::ImageResolver` — not a naive `find_by(label:)` — is the single
  # source of truth for label -> Image. A label can match several Image rows,
  # and only the resolver prefers the art-bearing one (most docs, lowest id to
  # break ties) and matches case-insensitively. `find_by` returns arbitrary
  # Postgres heap order, which is how this endpoint used to attach blank,
  # art-less duplicates to almost every tile.
  #
  # `resolved` is the batch pass's label -> Image map; a miss there falls back
  # to a single resolve so the two paths can never disagree.
  def resolve_image_from(p, resolved: nil)
    if p[:image_id].present?
      Image.find_by(id: p[:image_id])
    elsif p[:label].present?
      label = p[:label].to_s.strip
      resolved&.[](Boards::ImageResolver.normalize(label)) ||
        Boards::ImageResolver.resolve(label, owner: current_user)
    end
  end

  # The resolver matches case-insensitively, so "Run" can legitimately resolve
  # to an Image labeled "run". Keep the caller's authored casing on the cell
  # rather than silently renaming the tile — same rule as
  # `ImageResolver.upgrade_board_tiles!`.
  def pin_authored_label!(board_image, p, image)
    return unless label_path?(p)
    return if p[:display_label].present?

    authored = p[:label].to_s.strip
    return if authored.blank? || authored == image.label

    board_image.update(display_label: authored)
  end

  # Queue AI art for any label that resolved to an Image with no artwork.
  # Without this a tile for an unmatched label stays permanently blank: nothing
  # else in this flow ever enqueues generation.
  #
  # Covers art-less images the resolver *found*, not just ones it created — an
  # existing blank duplicate is every bit as blank as a fresh one.
  def queue_missing_art!(image_ids)
    return if image_ids.empty?
    return unless generate_missing?

    ids = Image.where(id: image_ids.uniq)
               .where.missing(:docs)
               .pluck(:id)
    return if ids.empty?

    ids.each_slice(GENERATE_BATCH_SIZE) do |batch|
      GenerateImagesJob.perform_async(batch, @board.id)
    end
  end

  # Generation is on by default (callers building a board expect filled tiles).
  # `generate_missing: false` opts out when the caller would rather ship blanks
  # than spend the OpenAI call.
  def generate_missing?
    return true if params[:generate_missing].nil?

    ActiveModel::Type::Boolean.new.cast(params[:generate_missing]) != false
  end

  # `replace: true` clears the board first, so even a blind retry converges on
  # the intended board instead of doubling it.
  def replace?
    ActiveModel::Type::Boolean.new.cast(params[:replace]) == true
  end

  def idempotency_key
    @idempotency_key ||= params[:idempotency_key].to_s.strip.presence
  end

  # Returns the cells a previous request with this key created, or nil if the
  # key is new. An empty result (every remembered cell has since been deleted)
  # counts as new — replaying nothing would be indistinguishable from a
  # no-op success.
  def replayed_cells(key)
    ids = Array(@board.settings.is_a?(Hash) ? @board.settings.dig("internal_bulk_keys", key) : nil)
    return nil if ids.empty?

    cells = @board.board_images.where(id: ids).index_by(&:id)
    ordered = ids.filter_map { |id| cells[id.to_i] }
    ordered.presence
  end

  # Recorded INSIDE the bulk transaction: a rolled-back write must not leave a
  # key behind that would make the caller's retry replay tiles that do not
  # exist.
  def remember_idempotency_key!(key, board_images)
    settings = (@board.settings.is_a?(Hash) ? @board.settings : {}).deep_dup
    keys = settings["internal_bulk_keys"].is_a?(Hash) ? settings["internal_bulk_keys"] : {}
    keys = keys.except(key).merge(key => board_images.map(&:id)).to_a.last(IDEMPOTENCY_KEY_HISTORY).to_h
    settings["internal_bulk_keys"] = keys
    @board.update_column(:settings, settings)
  end

  # The board's denormalized `layout` keys off BoardImage ids, so it goes stale
  # the moment a cell is removed. Repack first (a delete can free a cell a
  # displaced tile belongs in), then rewrite the board-level copy.
  def resync_layout!
    Boards::LayoutRepacker.repack!(@board)
    Boards::LayoutRepacker.resync_board_layout!(@board)
  end

  # Applies an update to one existing cell. Returns true, or an error string.
  #
  # A symbol swap re-points `image_id` on the SAME BoardImage rather than
  # delete-and-recreate: `layout` keys off BoardImage ids, so recreating would
  # orphan the layout entry and silently reflow the grid.
  def apply_cell_update!(board_image, p)
    if p[:image_id].present?
      image = Image.find_by(id: p[:image_id])
      return "image not found" if image.nil?

      if image.id != board_image.image_id
        board_image.image_id = image.id
        board_image.display_image_url = image.display_image_url(current_user).presence || image.src_url
        return board_image.errors.full_messages.join(", ") unless board_image.save
      end
    end

    return true if apply_optional_attributes!(board_image, p)

    board_image.errors.full_messages.join(", ")
  end

  def apply_optional_attributes!(board_image, p)
    updates = {}
    updates[:position]      = p[:position].to_i if p[:position].present?
    updates[:voice]         = VoiceService.normalize_voice(p[:voice]) if p[:voice].present?
    updates[:language]      = p[:language] if p[:language].present?
    updates[:display_label] = p[:display_label].to_s.strip if p[:display_label].present?

    # Folder tiles. predictive_board_id is the only thing that makes a tile open
    # another board, so without it an internal-key caller can build every board
    # in a set but never connect them.
    #
    # No extra validation is needed here on purpose: BoardImage's before_save
    # check_predictive_board nulls an id that points at nothing rather than
    # raising, and is_dynamic? ignores self-links. A bad value therefore
    # degrades to an ordinary word tile instead of 500ing a bulk request.
    updates[:predictive_board_id] = p[:predictive_board_id].to_i if p[:predictive_board_id].present?

    updates[:hidden]        = ActiveModel::Type::Boolean.new.cast(p[:hidden]) unless p[:hidden].nil?
    updates[:font_size]     = p[:font_size].to_i if p[:font_size].present?
    updates[:border_width]  = p[:border_width].to_i unless p[:border_width].nil?
    updates[:border_radius] = p[:border_radius].to_i unless p[:border_radius].nil?

    updates[:bg_color]      = ColorHelper.to_hex(p[:bg_color], default: "#FFFFFF") if p[:bg_color].present?
    updates[:text_color]    = ColorHelper.to_hex(p[:text_color], default: "#000000") if p[:text_color].present?
    updates[:border_color]  = ColorHelper.to_hex(p[:border_color], default: "#000000") if p[:border_color].present?

    unless p[:hide_label].nil?
      data = (board_image.data || {}).deep_dup
      data["hide_label"] = ActiveModel::Type::Boolean.new.cast(p[:hide_label])
      updates[:data] = data
    end

    return true if updates.empty?
    board_image.update(updates)
  end

  # Compact per-cell payload for the multi-cell endpoints.
  #
  # `BoardImage#api_view` costs several queries PER TILE (docs + their
  # ActiveStorage blobs, audio files, voice list, board lookups). For a 48-cell
  # bulk that is a few hundred queries run AFTER the transaction commits — the
  # exact shape of #574, where the write landed and the response still 500'd,
  # and the caller's retry then duplicated every tile. Everything here is
  # already loaded on the record. `view=full` opts back into `api_view` for
  # callers that need the heavier payload.
  def cell_view(board_image)
    return board_image.api_view(current_user) if full_view?

    {
      id: board_image.id,
      board_id: board_image.board_id,
      image_id: board_image.image_id,
      label: board_image.label,
      display_label: board_image.display_label,
      position: board_image.position,
      layout: board_image.layout,
      hidden: board_image.hidden,
      voice: board_image.voice,
      language: board_image.language,
      bg_color: board_image.bg_color,
      text_color: board_image.text_color,
      border_color: board_image.border_color,
      border_width: board_image.border_width,
      border_radius: board_image.border_radius,
      font_size: board_image.font_size,
      part_of_speech: board_image.part_of_speech,
      data: board_image.data,
      predictive_board_id: board_image.predictive_board_id,
      dynamic: board_image.is_dynamic?,
      src: board_image.display_image_url,
      display_image_url: board_image.display_image_url,
      status: board_image.status,
    }
  end

  def full_view?
    params[:view].to_s == "full"
  end
end
