class API::Internal::ImagesController < API::Internal::ApplicationController
  def create
    label = image_params[:label]

    if label.blank?
      render json: { error: "label is required" }, status: :unprocessable_content
      return
    end

    @image = Image.find_or_create_by(label: label, user_id: current_user.id) do |img|
      img.image_prompt = image_params[:image_prompt]
      img.image_type   = image_params[:image_type] || "User"
      img.private      = image_params[:private] || false
    end

    if @image.persisted?
      render json: @image.with_display_doc(current_user), status: :created
    else
      render json: { errors: @image.errors }, status: :unprocessable_content
    end
  end

  def generate
    label  = image_params[:label].presence || image_params[:image_prompt]
    prompt = image_params[:image_prompt].to_s.gsub("[[REPLACE_LABEL]]", "").strip

    if label.blank?
      render json: { error: "label or image_prompt is required" }, status: :unprocessable_content
      return
    end

    @image = if params[:id].present?
        Image.find(params[:id])
      else
        Image.find_or_create_by(
          label: label,
          user_id: current_user.id,
          private: false,
          image_prompt: prompt,
          image_type: "Generated",
        )
      end

    @image.image_prompt = prompt if prompt.present?
    @image.status = "generating"
    @image.save!

    options = {
      "image_prompt"   => @image.image_prompt,
      "board_id"       => params[:board_id],
      "screen_size"    => params[:screen_size] || "lg",
      "transparent_bg" => params[:transparent_background] == "true" || params[:transparent_background] == true,
    }
    GenerateImageJob.perform_async(@image.id, current_user.id, options)

    render json: image_status_payload(@image), status: :accepted
  end

  def show
    @image = Image.find(params[:id])
    render json: image_status_payload(@image)
  end

  private

  def image_status_payload(image)
    {
      id: image.id,
      label: image.label,
      status: image.status,
      image_prompt: image.image_prompt,
      src: image.display_image_url(current_user),
      error: image.error,
    }
  end

  def image_params
    params.require(:image).permit(
      :label,
      :image_prompt,
      :image_type,
      :private,
      :board_id,
    )
  end
end
