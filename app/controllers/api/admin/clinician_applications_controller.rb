# Admin review of SpeakAnyWay for Clinicians applications. Approval flips the
# applicant to the free `clinician` plan (Pro-level features, 2-slot loaner cap,
# 400 credits/mo). Admin-only: a signed-in non-admin gets 403 (repo invariant:
# 403 = permission/plan gate), an unauthenticated caller gets 401.
class API::Admin::ClinicianApplicationsController < API::ApplicationController
  before_action :authenticate_token!
  before_action :require_admin!

  # GET /api/admin/clinician_applications  (defaults to pending)
  # Optional ?status=approved|denied|pending|all
  def index
    scope = ClinicianApplication.all
    status = params[:status].presence || ClinicianApplication::PENDING
    scope = scope.where(status: status) unless status == "all"
    applications = scope.order(created_at: :desc).limit(500)
    render json: { applications: applications.map { |a| application_json(a) } }
  end

  # POST /api/admin/clinician_applications/:id/approve
  def approve
    application = ClinicianApplication.find_by(id: params[:id])
    return render_not_found unless application

    result = ClinicianApplications::Reviewer.approve!(application, admin: current_user, notes: params[:notes])
    if result.ok
      render json: { application: application_json(application.reload) }
    else
      render json: { error: result.error, message: review_error_message(result.error) }, status: :unprocessable_content
    end
  end

  # POST /api/admin/clinician_applications/:id/deny
  def deny
    application = ClinicianApplication.find_by(id: params[:id])
    return render_not_found unless application

    result = ClinicianApplications::Reviewer.deny!(application, admin: current_user, notes: params[:notes])
    if result.ok
      render json: { application: application_json(application.reload) }
    else
      render json: { error: result.error, message: review_error_message(result.error) }, status: :unprocessable_content
    end
  end

  private

  def require_admin!
    return if current_user&.admin?
    render json: { error: "forbidden", message: "Admin access required." }, status: :forbidden
  end

  def render_not_found
    render json: { error: "not_found", message: "Application not found." }, status: :not_found
  end

  def review_error_message(error)
    case error
    when "not_pending" then "This application has already been reviewed."
    else "Could not update this application."
    end
  end

  def application_json(application)
    {
      id: application.id,
      user_id: application.user_id,
      user_email: application.user&.email,
      status: application.status,
      full_name: application.full_name,
      credential_type: application.credential_type,
      license_id: application.license_id,
      workplace: application.workplace,
      reviewed_by_id: application.reviewed_by_id,
      reviewed_at: application.reviewed_at&.iso8601,
      notes: application.notes,
      created_at: application.created_at&.iso8601,
    }
  end
end
