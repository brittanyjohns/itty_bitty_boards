class API::Internal::ImagesController < API::Internal::ApplicationController
  # Bulk search is a per-label query loop; the cap keeps it off a table scan.
  MAX_BULK_LABELS = 100

  # limit_per_label multiplies across every label in a bulk request, so it
  # gets a tighter cap than the single-label GET endpoint's
  # Images::LabelSearch::MAX_LIMIT (50): 100 labels * 25 = 2,500 results is
  # generous; 100 * 50 = 5,000 is not intended.
  MAX_BULK_LIMIT_PER_LABEL = 25

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

  # GET /api/internal/images/search?q=apple
  def search
    label = params[:q].to_s.strip

    if label.blank?
      render json: { error: "q is required" }, status: :unprocessable_content
      return
    end

    render json: { query: label, results: label_search.call(label) }
  end

  # POST /api/internal/images/search { labels: [...] }
  #
  # Every requested label gets a key in the response — including misses, as an
  # empty array — so the caller can spot gaps without diffing its request.
  def bulk_search
    labels = Array(params[:labels]).map(&:to_s)

    if labels.empty?
      render json: { error: "labels is required" }, status: :unprocessable_content
      return
    end

    if labels.size > MAX_BULK_LABELS
      render json: { error: "labels exceeds the maximum of #{MAX_BULK_LABELS}" },
             status: :unprocessable_content
      return
    end

    search = label_search(limit: bulk_limit_per_label, default_limit: 3)
    render json: { results: labels.index_with { |label| search.call(label) } }
  end

  private

  def bulk_limit_per_label
    return nil if params[:limit_per_label].blank?

    params[:limit_per_label].to_i.clamp(1, MAX_BULK_LIMIT_PER_LABEL)
  end

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

  def label_search(limit: nil, default_limit: nil)
    Images::LabelSearch.new(
      match: params[:match],
      limit: limit || params[:limit] || default_limit || Images::LabelSearch::DEFAULT_LIMIT,
      commercial_safe: truthy_param?(params[:commercial_safe]),
      include_share_alike: truthy_param?(params[:include_share_alike]),
    )
  end

  def truthy_param?(value)
    ["true", "1", true].include?(value.is_a?(String) ? value.downcase : value)
  end
end
