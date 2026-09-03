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
      stamp_clinician_apply_signup!(application)
      ClinicianMailer.application_received_email(application).deliver_later
      render json: { application: application_json(application) }, status: :created
    else
      # `errors` is additive — `message` keeps carrying the full sentence
      # verbatim, so an older client is unaffected — and lets the form put the
      # license refusal under the license field instead of in a page-level
      # banner, which is where it has to appear for the offered alternative to
      # make sense.
      render json: {
        error: "invalid_application",
        message: application.errors.full_messages.to_sentence,
        errors: application.errors.to_hash(true),
      }, status: :unprocessable_content
    end
  end

  # GET /api/clinician_applications/mine
  # The user's most recent application (any status), or null if none.
  def mine
    application = current_user.clinician_applications.order(created_at: :desc).first
    render json: { application: application ? application_json(application) : nil }
  end

  private

  # How close to signup an application has to be for this endpoint to conclude
  # the account came from the apply page.
  SIGNUP_ATTRIBUTION_WINDOW = 15.minutes

  # Bridge for clients that don't yet send `signup_method: "clinician_apply"` to
  # the signup endpoint — the real fix, since only the signup request knows
  # which form the account came from.
  #
  # Deliberately narrow, because this rewrites PROVENANCE and provenance that
  # can be rewritten later is worth nothing: it fires only on a FIRST
  # application, from an account minted inside SIGNUP_ATTRIBUTION_WINDOW, whose
  # method is still the generic "standard". A long-standing user who applies
  # years later keeps the stamp their signup actually earned. Fail-soft — a
  # settings write must never cost the applicant the application they just
  # filed.
  def stamp_clinician_apply_signup!(application)
    user = application.user
    return unless user.clinician_applications.count == 1
    return unless user.created_at.present? && user.created_at > SIGNUP_ATTRIBUTION_WINDOW.ago

    settings = user.settings || {}
    return unless settings["signup_method"].blank? || settings["signup_method"] == "standard"

    user.update(settings: settings.merge("signup_method" => "clinician_apply"))
  rescue StandardError => e
    Rails.logger.error("[ClinicianApplication] signup attribution failed for user #{user&.id}: #{e.message}")
  end

  def application_params
    params.require(:clinician_application).permit(
      # `verification_note` is the applicant's answer to "how should we verify
      # you?" — the alternative offered when a license number is refused or
      # doesn't exist. Distinct from `notes`, which is the ADMIN's review note
      # and is never applicant-writable.
      :full_name, :credential_type, :license_id, :workplace, :verification_note,
    )
  end

  def application_json(application)
    {
      id: application.id,
      status: application.status,
      full_name: application.full_name,
      credential_type: application.credential_type,
      license_id: application.license_id,
      license_required: application.license_required?,
      verification_note: application.verification_note,
      workplace: application.workplace,
      reviewed_at: application.reviewed_at&.iso8601,
      created_at: application.created_at&.iso8601,
    }
  end
end
