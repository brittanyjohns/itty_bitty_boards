class API::Internal::BoardImagesController < API::Internal::ApplicationController
  def create
    @board = Board.find(params[:board_id])

    image = resolve_image_from(params)
    return render json: { error: "image_id or label is required" }, status: :unprocessable_entity if image.nil?

    board_image = @board.add_image(image.id)

    if board_image&.persisted?
      apply_optional_attributes!(board_image, params)
      render json: board_image.api_view(current_user), status: :created
    else
      errors = board_image&.errors&.full_messages&.join(", ") || "Unable to add image to board"
      render json: { error: errors }, status: :unprocessable_entity
    end
  end

  def bulk
    @board = Board.find(params[:board_id])

    raw_cells = params[:cells]
    unless raw_cells.is_a?(Array) && raw_cells.any?
      return render json: { error: "cells must be a non-empty array" }, status: :unprocessable_entity
    end

    created = []
    errors = []

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

        created << board_image
      end

      raise ActiveRecord::Rollback if errors.any?
    end

    if errors.any?
      render json: { errors: errors }, status: :unprocessable_entity
    else
      render json: created.map { |bi| bi.api_view(current_user) }, status: :created
    end
  end

  private

  def resolve_image_from(p)
    if p[:image_id].present?
      Image.find_by(id: p[:image_id])
    elsif p[:label].present?
      language = p[:language].presence || @board&.language.presence || "en"
      Image.find_or_create_for_label(p[:label], language: language, user: current_user)
    end
  end

  def apply_optional_attributes!(board_image, p)
    updates = {}
    updates[:position]      = p[:position].to_i if p[:position].present?
    updates[:voice]         = VoiceService.normalize_voice(p[:voice]) if p[:voice].present?
    updates[:language]      = p[:language] if p[:language].present?
    updates[:display_label] = p[:display_label].to_s.strip if p[:display_label].present?

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
