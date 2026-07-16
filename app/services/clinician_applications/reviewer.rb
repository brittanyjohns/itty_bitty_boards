# frozen_string_literal: true

module ClinicianApplications
  # Shared approve/deny logic for a ClinicianApplication, used by BOTH the JSON
  # admin API (API::Admin::ClinicianApplicationsController) and the server-
  # rendered admin dashboard (Admin::ClinicianApplicationsController) so the two
  # entry points can never drift (plan flip, credit grant, and emails stay in one
  # place). Returns a Result (ok + error slug) instead of raising, so each
  # controller renders its own response.
  class Reviewer
    Result = Struct.new(:ok, :error, keyword_init: true)

    def self.approve!(application, admin:, notes: nil)
      new(application, admin: admin, notes: notes).approve!
    end

    def self.deny!(application, admin:, notes: nil)
      new(application, admin: admin, notes: notes).deny!
    end

    def initialize(application, admin:, notes: nil)
      @application = application
      @admin = admin
      @notes = notes
    end

    # Flip the applicant to the free `clinician` plan (setup_limits + reconcile
    # callbacks fire on save) and grant the clinician credit allowance. Clinician
    # is free / no Stripe invoice, so credits are granted synchronously here (same
    # pattern as the partner_pro comp grant). Idempotent-ish: refuses a
    # non-pending application.
    def approve!
      return Result.new(ok: false, error: "not_pending") unless @application.pending?

      user = @application.user
      ActiveRecord::Base.transaction do
        user.plan_type = "clinician"
        user.plan_status = "active"
        user.save!

        @application.update!(
          status: ClinicianApplication::APPROVED,
          reviewed_by_id: @admin&.id,
          reviewed_at: Time.current,
          notes: @notes.presence || @application.notes,
        )
      end

      grant_clinician_credits!(user)
      ClinicianMailer.approved_email(@application).deliver_later
      Result.new(ok: true)
    rescue => e
      Rails.logger.error "[ClinicianApplications::Reviewer] approve failed for ##{@application&.id}: #{e.class} - #{e.message}"
      Result.new(ok: false, error: "approve_failed")
    end

    def deny!
      return Result.new(ok: false, error: "not_pending") unless @application.pending?

      @application.update!(
        status: ClinicianApplication::DENIED,
        reviewed_by_id: @admin&.id,
        reviewed_at: Time.current,
        notes: @notes.presence,
      )

      ClinicianMailer.denied_email(@application).deliver_later
      Result.new(ok: true)
    rescue => e
      Rails.logger.error "[ClinicianApplications::Reviewer] deny failed for ##{@application&.id}: #{e.class} - #{e.message}"
      Result.new(ok: false, error: "deny_failed")
    end

    private

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
      Rails.logger.error "[ClinicianApplications::Reviewer] credit grant failed for user=#{user.id}: #{e.class} - #{e.message}"
    end
  end
end
