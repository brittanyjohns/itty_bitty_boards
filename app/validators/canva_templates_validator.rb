# Validates a `canva_templates` jsonb column: a list of
# `{"label", "url", "description"}` rows, each linking an editable Canva design.
#
# Shared by KitPage (a template a visitor gets after an email) and
# PrintableProduct (a template a buyer gets with a purchase). One copy, because
# the URL allowlist is the whole protection: a second copy is a second list to
# forget to update.
#
#   validates :canva_templates, canva_templates: { max: 5 }
#
# The link is checked against an ALLOWLIST of host and path, never an
# exclusion: a new Canva URL shape has to be opted in, not merely "not excluded".
#
# Canva's Share menu hands out TWO shapes and both are legitimate — the full
# design URL, and a `canva.link` short link that 301s to one. Neither is
# rewritten on the way in: the shortener is Canva's own, a visitor following it
# lands in the same place, and resolving it here would make saving an admin
# form depend on a third-party request that can hang or fail.
class CanvaTemplatesValidator < ActiveModel::EachValidator
  DESIGN_HOSTS = ["canva.com", "www.canva.com"].freeze
  DESIGN_PATH_PREFIX = "/design/".freeze
  SHORT_HOSTS = ["canva.link"].freeze

  def self.allowed_url?(value)
    uri = URI.parse(value.to_s)
    return false unless uri.scheme == "https"

    if DESIGN_HOSTS.include?(uri.host)
      uri.path.to_s.start_with?(DESIGN_PATH_PREFIX)
    elsif SHORT_HOSTS.include?(uri.host)
      # The shortener's entire path IS the id, so there is no prefix to check —
      # only that the link names something rather than the bare domain.
      uri.path.to_s.delete_prefix("/").present?
    else
      false
    end
  rescue URI::InvalidURIError
    false
  end

  # Rows a visitor can actually be sent to. A row missing its link is dropped
  # rather than published as a dead button.
  def self.usable(rows)
    Array(rows).select { |row| row.is_a?(Hash) && row["url"].present? }
  end

  def validate_each(record, attribute, value)
    return record.errors.add(attribute, "must be a list") unless value.is_a?(Array)

    max = options[:max]
    record.errors.add(attribute, "can have at most #{max} templates") if max && value.size > max

    value.each_with_index do |row, index|
      position = index + 1

      unless row.is_a?(Hash)
        record.errors.add(attribute, "template #{position} must be an object")
        next
      end

      record.errors.add(attribute, "template #{position} needs a label") if row["label"].blank?

      if row["url"].blank?
        record.errors.add(attribute, "template #{position} needs a Canva link")
      elsif !self.class.allowed_url?(row["url"])
        # Names BOTH accepted shapes: a refusal that only says no makes the
        # second shape read as a bug.
        record.errors.add(attribute, "template #{position} must be an https canva.com/design/… or canva.link/… link")
      end
    end
  end
end
