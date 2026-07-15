module Admin
  # Server-rendered admin dashboard for SpeakAnyWay for Clinicians applications.
  # Approve/deny share ClinicianApplications::Reviewer with the JSON admin API,
  # so both stay in lockstep. Auth (sign-in + admin) comes from
  # Admin::ApplicationController.
  class ClinicianApplicationsController < Admin::ApplicationController
    STATUSES = %w[pending approved denied all].freeze

    def index
      @status = params[:status].presence_in(STATUSES) || "pending"
      scope = ClinicianApplication.includes(:user, :reviewed_by).order(created_at: :desc)
      scope = scope.where(status: @status) unless @status == "all"
      @applications = scope.limit(500)
      @pending_count = ClinicianApplication.pending.count
    end

    def approve
      application = ClinicianApplication.find_by(id: params[:id])
      return redirect_back_with_alert("Application not found.") unless application

      result = ClinicianApplications::Reviewer.approve!(application, admin: current_user, notes: params[:notes])
      if result.ok
        redirect_to_index notice: "Approved #{application.user.email} — now on the Clinician plan."
      else
        redirect_to_index alert: review_error_message(result.error)
      end
    end

    def deny
      application = ClinicianApplication.find_by(id: params[:id])
      return redirect_back_with_alert("Application not found.") unless application

      result = ClinicianApplications::Reviewer.deny!(application, admin: current_user, notes: params[:notes])
      if result.ok
        redirect_to_index notice: "Denied #{application.user.email}'s application."
      else
        redirect_to_index alert: review_error_message(result.error)
      end
    end

    private

    def redirect_to_index(flash_opts)
      redirect_to admin_dashboard_clinician_applications_path(status: params[:status].presence_in(STATUSES)), **flash_opts
    end

    def redirect_back_with_alert(message)
      redirect_to admin_dashboard_clinician_applications_path, alert: message
    end

    def review_error_message(error)
      case error
      when "not_pending" then "This application has already been reviewed."
      else "Could not update this application. Please try again."
      end
    end
  end
end
