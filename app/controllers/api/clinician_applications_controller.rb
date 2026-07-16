# Public (authenticated-user) endpoints for the SpeakAnyWay for Clinicians
# program. A signed-in user submits one application; an admin reviews it in
# API::Admin::ClinicianApplicationsController.
class API::ClinicianApplicationsController < API::ApplicationController
  before_action :authenticate_token!

  # POST /api/clinician_applications
  # One pending application at a time. If the user already has a pending one,
  # return it (422) rather than creating a duplicate.
  def create
    existing = current_user.clinician_applications.pending.first
    if existing
      render json: { error: "application_pending", message: "You already have a clinician application under review.", application: application_json(existing) }, status: :unprocessable_content
      return
    end

    application = current_user.clinician_applications.new(application_params)
    application.status = ClinicianApplication::PENDING

    if application.save
      ClinicianMailer.application_received_email(application).deliver_later
      render json: { application: application_json(application) }, status: :created
    else
      render json: { error: "invalid_application", message: application.errors.full_messages.to_sentence }, status: :unprocessable_content
    end
  end

  # GET /api/clinician_applications/mine
  # The user's most recent application (any status), or null if none.
  def mine
    application = current_user.clinician_applications.order(created_at: :desc).first
    render json: { application: application ? application_json(application) : nil }
  end

  private

  def application_params
    params.require(:clinician_application).permit(
      :full_name, :credential_type, :license_id, :workplace,
    )
  end

  def application_json(application)
    {
      id: application.id,
      status: application.status,
      full_name: application.full_name,
      credential_type: application.credential_type,
      license_id: application.license_id,
      workplace: application.workplace,
      reviewed_at: application.reviewed_at&.iso8601,
      created_at: application.created_at&.iso8601,
    }
  end
end
