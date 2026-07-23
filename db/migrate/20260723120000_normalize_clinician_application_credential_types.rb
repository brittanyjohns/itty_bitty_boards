# Backfill credential_type to the canonical CREDENTIAL_TYPES slugs.
#
# The web client sent display labels ("SLP", "AT specialist") while the model
# defined — but never validated against — %w[slp ot at_specialist other], so
# un-normalized values reached the admin review queue. The inclusion validation
# added alongside this migration would reject those rows on any later save.
#
# update_column skips validations and callbacks on purpose: these rows are being
# corrected *to* the valid form, and a pending-uniqueness validation could
# otherwise block an already-persisted duplicate from being fixed.
class NormalizeClinicianApplicationCredentialTypes < ActiveRecord::Migration[8.0]
  def up
    ClinicianApplication.reset_column_information

    ClinicianApplication.find_each do |application|
      raw = application.credential_type
      next if raw.blank?

      normalized = ClinicianApplication.normalize_credential_type(raw)
      next if normalized == raw

      say "ClinicianApplication ##{application.id}: #{raw.inspect} → #{normalized.inspect}"
      application.update_column(:credential_type, normalized)
    end
  end

  # Irreversible by design: the original casing carried no information the
  # slug doesn't, and rows that normalized to "other" can't be mapped back.
  def down
    say "No-op: credential_type normalization is not reversible."
  end
end
