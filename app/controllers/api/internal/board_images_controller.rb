class API::Internal::BoardImagesController < API::Internal::ApplicationController
  # AI generation is queued in slices, mirroring
  # `Board#find_or_create_images_from_word_list`, so one 60-tile build doesn't
  # become one 60-image Sidekiq job.
  GENERATE_BATCH_SIZE = 3

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

    created = []
    errors = []
    label_resolved_image_ids = []

    ActiveRecord::Base.transaction do
      raw_cells.each_with_index do |cell_params, index|
        # ActionController::Parameters in nested arrays come through as
        # ActionController::Parameters instances; coerce to a hash with
        # indifferent access so resolve_image_from / apply_optional_attributes!
        # work the same way as in #create.
        cp = cell_params.respond_to?(:permit!) ? cell_params.permit!.to_h.with_indifferent_access : cell_params.to_h.with_indifferent_access

        image = resolve_image_from(cp)
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

      raise ActiveRecord::Rollback if errors.any?
    end

    if errors.any?
      render json: { errors: errors }, status: :unprocessable_content
    else
      # Only after the transaction has actually committed — a rolled-back bulk
      # must not leave Sidekiq holding ids of Images that no longer exist.
      queue_missing_art!(label_resolved_image_ids)
      render json: created.map { |bi| bi.api_view(current_user) }, status: :created
    end
  end

  private

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
  def resolve_image_from(p)
    if p[:image_id].present?
      Image.find_by(id: p[:image_id])
    elsif p[:label].present?
      Boards::ImageResolver.resolve(p[:label].to_s.strip, owner: current_user)
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
end
