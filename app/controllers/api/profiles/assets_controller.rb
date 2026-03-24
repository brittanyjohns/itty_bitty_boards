# app/controllers/api/profiles/assets_controller.rb
class API::Profiles::AssetsController < API::ApplicationController
  before_action :set_profile

  def safety_id
    Rails.logger.info "Generating safety ID for Profile ID: #{@profile.id}, Regenerate: #{params[:regenerate]}"
    Communicators::GenerateSafetyIdCard.call(@profile, regenerate: truthy?(params[:regenerate]))

    attachment =
      params[:format_type] == "pdf" ? @profile.safety_id_pdf : @profile.safety_id_png

    if attachment.attached?
      render json: { url: @profile.url_for_attachment(attachment) }
    else
      render json: { error: "Unable to generate safety ID." }, status: :unprocessable_entity
    end
  end

  def device_tag
    Rails.logger.info "Generating device tag for Profile ID: #{@profile.id}, Regenerate: #{params[:regenerate]}"
    Communicators::GenerateDeviceTag.call(@profile, regenerate: truthy?(params[:regenerate]))

    attachment =
      params[:format_type] == "pdf" ? @profile.device_tag_pdf : @profile.device_tag_png

    if attachment.attached?
      render json: { url: @profile.url_for_attachment(attachment) }
    else
      render json: { error: "Unable to generate device tag." }, status: :unprocessable_entity
    end
  end

  private

  def set_profile
    if params[:id]
      @profile = Profile.find_by(id: params[:id])
    else
      @profile = current_user.profile
    end

    head :not_found unless @profile
  end

  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end
end
