# app/controllers/api/profiles/assets_controller.rb
class API::Profiles::AssetsController < API::ApplicationController
  before_action :set_profile
  before_action :require_owner!

  def safety_id
    Rails.logger.info "Generating safety ID for Profile ID: #{@profile.id}, Regenerate: #{params[:regenerate]}"
    Communicators::GenerateSafetyIdCard.call(@profile, regenerate: truthy?(params[:regenerate]))

    attachment =
      params[:format_type] == "pdf" ? @profile.safety_id_pdf : @profile.safety_id_png

    if attachment.attached?
      render json: { url: @profile.url_for_attachment(attachment) }
    else
      render json: { error: "Unable to generate safety ID." }, status: :unprocessable_content
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
      render json: { error: "Unable to generate device tag." }, status: :unprocessable_content
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

  # Authentication alone is not authorization here. Both actions hand back
  # `url_for_attachment`, which is an UNSIGNED CloudFront URL — so serving one
  # for someone else's profile publishes that communicator's allergies,
  # medications, and emergency contacts to whoever asked, permanently. Profile
  # ids are sequential, so "they'd have to guess the id" is not a defense.
  #
  # Mirrors the gate on API::ProfilesController#update, which has always had
  # one; this controller was simply never given it.
  def require_owner!
    return if owner_of_profile?

    render json: { error: "not_owner" }, status: :forbidden
  end

  # Closed by default: an unrecognized profileable type is refused rather than
  # allowed, so adding a new one can't silently open this up. `profileable` is
  # `optional: true`, so an orphaned profile safe-navigates to nil and is
  # refused — a 403 rather than a 500.
  def owner_of_profile?
    return false unless current_user

    case @profile.profileable_type
    when "ChildAccount"
      @profile.profileable&.editable_by?(current_user)
    when "User"
      @profile.profileable_id == current_user.id || current_user.admin?
    else
      current_user.admin?
    end
  end

  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end
end
