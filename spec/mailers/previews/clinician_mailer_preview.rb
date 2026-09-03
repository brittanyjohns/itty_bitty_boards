# Preview at http://localhost:4000/rails/mailers/clinician_mailer
class ClinicianMailerPreview < ActionMailer::Preview
  def application_received_email
    ClinicianMailer.application_received_email(preview_application)
  end

  def approved_email
    ClinicianMailer.approved_email(preview_application)
  end

  # Denial with an admin note, so the optional quoted-note branch is visible.
  def denied_email
    ClinicianMailer.denied_email(preview_application(notes: "We couldn't match that license number."))
  end

  private

  def preview_application(notes: nil)
    application = ClinicianApplication.order(created_at: :desc).first || ClinicianApplication.new(
      user: User.first || User.new(name: "Sam Lee", email: "sam@example.com"),
      status: ClinicianApplication::PENDING,
      full_name: "Samantha Lee, MS CCC-SLP",
      credential_type: "slp",
      license_id: "SLP-12345",
      license_id: "SLP-12345",
      workplace: "Riverside Clinic",
    )
    application.notes = notes
    application
  end
end
