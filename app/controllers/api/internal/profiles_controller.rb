class API::Internal::ProfilesController < API::Internal::ApplicationController
  before_action :find_profile!

  def show
    render json: response_payload
  end

  def update
    apply_rich_text_fields

    if @profile.update(profile_params)
      @profile.enqueue_audio_job_if_needed
      @profile.generate_attachments! if @profile.safety?
      render json: response_payload
    else
      Rails.logger.debug("[Internal::Profiles#update] errors=#{@profile.errors.full_messages}")
      render json: {
        error: "Profile update failed",
        details: @profile.errors.full_messages,
      }, status: :unprocessable_entity
    end
  end

  private

  def find_profile!
    @profile = Profile.find_by(id: params[:id]) if params[:id].to_s.match?(/\A\d+\z/)
    @profile ||= Profile.find_by(slug: params[:id])

    render json: { error: "Profile not found" }, status: :not_found unless @profile
  end

  def apply_rich_text_fields
    {
      public_about: params.dig(:profile, :public_about_html),
      public_intro: params.dig(:profile, :public_intro_html),
      public_bio: params.dig(:profile, :public_bio_html),
    }.each do |attr, html|
      @profile.public_send("#{attr}=", html) if html.present?
    end
  end

  def profile_params
    params.require(:profile).permit(
      :username, :bio, :intro, :avatar, :allow_discovery,
      settings: {},
    )
  end

  def response_payload
    {
      profile: @profile.api_view(current_user),
      assets: attachment_urls,
    }
  end

  def attachment_urls
    {
      safety_id_png_url: url_for_attached(@profile.safety_id_png),
      safety_id_pdf_url: url_for_attached(@profile.safety_id_pdf),
      device_tag_png_url: url_for_attached(@profile.device_tag_png),
      device_tag_pdf_url: url_for_attached(@profile.device_tag_pdf),
    }.compact
  end

  def url_for_attached(attachment)
    return nil unless attachment.attached?
    @profile.url_for_attachment(attachment)
  end
end
