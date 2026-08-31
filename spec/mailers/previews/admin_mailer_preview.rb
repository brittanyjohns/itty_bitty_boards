# Preview all emails at http://localhost:4000/rails/mailers/admin_mailer
class AdminMailerPreview < ActionMailer::Preview
  def new_user_email
    AdminMailer.new_user_email(preview_user)
  end

  def plan_change_email
    AdminMailer.plan_change_email(preview_user, from_plan: "free", to_plan: "pro", source: "stripe")
  end

  def new_nomination_email
    AdminMailer.new_nomination_email(preview_nomination)
  end

  def new_clinician_application_email
    AdminMailer.new_clinician_application_email(preview_clinician_application)
  end

  private

  # A real application when one exists, otherwise an unsaved stand-in so the
  # preview renders on a fresh database.
  def preview_clinician_application
    ClinicianApplication.order(created_at: :desc).first || ClinicianApplication.new(
      id: 0,
      user: preview_user,
      status: ClinicianApplication::PENDING,
      full_name: "Alex Rivera",
      credential_type: "at_specialist",
      license_id: "AT-98765",
      workplace: "Riverside School District",
      created_at: Time.current,
    )
  end

  # Uses a real nomination when one exists, otherwise an unsaved stand-in so the
  # preview renders on a fresh database.
  def preview_nomination
    DownloadLead.nominations.order(created_at: :desc).first || DownloadLead.new(
      id: 0,
      email: "nominator@example.com",
      name: "Jane Doe",
      source: DownloadLead::NOMINATION_SOURCE,
      created_at: Time.current,
      data: {
        "park" => "LaGrange Community Park",
        "city" => "LaGrange, OH",
        "role" => "Parent / caregiver",
        "why" => "Our son swings here every day and there are no words on the swings.",
        "sponsor_interest" => "Yes",
        "marketing_opt_in" => true,
      },
    )
  end

  def preview_user
    User.non_admin.order(created_at: :desc).first || User.first
  end
end
