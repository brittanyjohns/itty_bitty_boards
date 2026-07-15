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
    unless application.pending?
      return render json: { error: "not_pending", message: "This application has already been reviewed." }, status: :unprocessable_content
    end

    user = application.user
    ActiveRecord::Base.transaction do
      # Flip the plan. setup_limits + reconcile callbacks fire on save.
      user.plan_type = "clinician"
      user.plan_status = "active"
      user.save!

      application.update!(
        status: ClinicianApplication::APPROVED,
        reviewed_by_id: current_user.id,
        reviewed_at: Time.current,
        notes: params[:notes].presence || application.notes,
      )
    end

    # Grant the clinician credit allowance immediately. Clinician is a free,
    # non-Stripe plan, so no webhook/invoice ever fires — this is the same
    # synchronous-grant pattern used for the partner_pro comp plan. Idempotent
    # full reset; safe outside the txn.
    grant_clinician_credits!(user)

    ClinicianMailer.approved_email(application).deliver_later
    render json: { application: application_json(application.reload) }
  rescue => e
    Rails.logger.error "[Admin][ClinicianApplications] approve failed for ##{params[:id]}: #{e.class} - #{e.message}"
    render json: { error: "approve_failed", message: "Could not approve this application." }, status: :unprocessable_content
  end

  # POST /api/admin/clinician_applications/:id/deny
  def deny
    application = ClinicianApplication.find_by(id: params[:id])
    return render_not_found unless application
    unless application.pending?
      return render json: { error: "not_pending", message: "This application has already been reviewed." }, status: :unprocessable_content
    end

    application.update!(
      status: ClinicianApplication::DENIED,
      reviewed_by_id: current_user.id,
      reviewed_at: Time.current,
      notes: params[:notes].presence,
    )

    ClinicianMailer.denied_email(application).deliver_later
    render json: { application: application_json(application) }
  rescue => e
    Rails.logger.error "[Admin][ClinicianApplications] deny failed for ##{params[:id]}: #{e.class} - #{e.message}"
    render json: { error: "deny_failed", message: "Could not deny this application." }, status: :unprocessable_content
  end

  private

  def require_admin!
    return if current_user&.admin?
    render json: { error: "forbidden", message: "Admin access required." }, status: :forbidden
  end

  def render_not_found
    render json: { error: "not_found", message: "Application not found." }, status: :not_found
  end

  def grant_clinician_credits!(user)
    amount = CreditService.monthly_credits_for("clinician")
    return if amount <= 0 || user.admin?

    CreditService.grant_plan!(
      user,
      amount: amount,
      period_end: CreditService.initial_period_end_for("clinician"),
      metadata: { source: "clinician_approval", plan_type: "clinician" },
    )
  rescue => e
    Rails.logger.error "[Admin][ClinicianApplications] credit grant failed for user=#{user.id}: #{e.class} - #{e.message}"
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
