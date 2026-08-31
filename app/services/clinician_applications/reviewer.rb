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
      notify_applicant(ClinicianMailer.approved_email(@application))
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

      notify_applicant(ClinicianMailer.denied_email(@application))
      Result.new(ok: true)
    rescue => e
      Rails.logger.error "[ClinicianApplications::Reviewer] deny failed for ##{@application&.id}: #{e.class} - #{e.message}"
      Result.new(ok: false, error: "deny_failed")
    end

    private

    # The applicant email is a notification, not part of the review. By the time
    # it runs the plan flip, the status update and the credit grant have all
    # committed, so a Redis/ActiveJob blip must never report the review as failed
    # — a retry would only hit the `not_pending` guard and tell the admin it was
    # already reviewed (repo invariant: external-service failures fail soft).
    # Called after the transaction so the job can never name an uncommitted row.
    def notify_applicant(mail)
      mail.deliver_later
    rescue => e
      Rails.logger.error "[ClinicianApplications::Reviewer] applicant email failed for ##{@application&.id}: #{e.class} - #{e.message}"
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
      Rails.logger.error "[ClinicianApplications::Reviewer] credit grant failed for user=#{user.id}: #{e.class} - #{e.message}"
    end
  end
end
