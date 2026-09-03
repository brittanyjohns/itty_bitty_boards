# The free-text alternative to a license number. The application form hard-
# required a license or certification number, which stopped nobody willing to
# type "N/A" and blocked exactly the applicants most likely to be legitimate
# but unlicensed — `at_specialist` (RESNA ATP is optional, and the page
# recruits them in its H1) and `other`. A rejection has to be able to offer
# something else, so the alternative gets a column of its own rather than
# sharing `notes`, which is the ADMIN's review note and is rendered as one.
class AddVerificationNoteToClinicianApplications < ActiveRecord::Migration[8.0]
  def change
    add_column :clinician_applications, :verification_note, :text
  end
end
