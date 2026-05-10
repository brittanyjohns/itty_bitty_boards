class API::Internal::BoardImagesController < API::Internal::ApplicationController
  def create
    @board = Board.find(params[:board_id])

    image = resolve_image
    return render json: { error: "image_id or label is required" }, status: :unprocessable_entity if image.nil?

    board_image = @board.add_image(image.id)

    if board_image&.persisted?
      apply_optional_attributes!(board_image)
      render json: board_image.api_view(current_user), status: :created
    else
      errors = board_image&.errors&.full_messages&.join(", ") || "Unable to add image to board"
      render json: { error: errors }, status: :unprocessable_entity
    end
  end

  private

  def resolve_image
    if params[:image_id].present?
      Image.find_by(id: params[:image_id])
    elsif params[:label].present?
      label = params[:label].to_s.strip
      Image.find_by(label: label, user_id: current_user.id) ||
        Image.public_img.find_by(label: label, user_id: [User::DEFAULT_ADMIN_ID, nil]) ||
        Image.create(label: label, user_id: current_user.id)
    end
  end

  def apply_optional_attributes!(board_image)
    updates = {}
    updates[:position]      = params[:position].to_i if params[:position].present?
    updates[:voice]         = VoiceService.normalize_voice(params[:voice]) if params[:voice].present?
    updates[:language]      = params[:language] if params[:language].present?
    updates[:display_label] = params[:display_label].to_s.strip if params[:display_label].present?
    board_image.update(updates) if updates.any?
  end
end
