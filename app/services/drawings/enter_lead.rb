module Drawings
  # Enters a freshly-saved DownloadLead into that day's booth drawing, if one
  # is configured for the lead's `source`. Called from
  # API::DownloadLeadsController#create after a successful save — deliberately
  # NOT a model callback, so other lead writers don't grow drawing side effects
  # by surprise. #910
  #
  # Return value is the `drawing` key of the download_leads 201 body:
  #   nil                                  -> no drawing configured today; the
  #                                           controller omits `drawing` entirely
  #   { entered: true, event_name: "..." } -> entered (new or already in)
  #   { entered: false }                   -> a drawing exists but entry failed
  #
  # The drawing NEVER fails the lead. The bundle email matters more than the
  # drawing, so every error is logged and swallowed.
  class EnterLead
    def self.call(lead, at: Time.current)
      new(lead, at: at).call
    end

    def initialize(lead, at: Time.current)
      @lead = lead
      @at = at
    end

    def call
      event = drawing_event
      return nil if event.nil?

      enter(event)
    end

    private

    attr_reader :lead, :at

    def drawing_event
      Event.drawing_for(source: lead.source, at: at)
    rescue StandardError => e
      log_failure(e, "looking up today's drawing")
      nil
    end

    # Same email, same day -> no new row, still entered. ContestEntry
    # normalizes (strip + downcase) on before_validation and its uniqueness is
    # case-insensitive (#909), so the stored emails are already normalized and
    # a plain find_by on the normalized value is the right lookup.
    def enter(event)
      existing = event.contest_entries.find_by(email: normalized_email)
      return entered(event) if existing

      event.contest_entries.create!(
        email: normalized_email,
        name: entry_name,
        data: { download_lead_id: lead.id, utm: lead.data },
      )
      entered(event)
    rescue StandardError => e
      log_failure(e, "entering lead #{lead.id} into event #{event.id}")
      { entered: false }
    end

    def entered(event)
      { entered: true, event_name: event.name }
    end

    def normalized_email
      lead.email.to_s.strip.downcase
    end

    # ContestEntry requires a name and /ctg only collects an email, so fall
    # back to the local part of the address.
    def entry_name
      lead.name.presence || normalized_email.split("@").first
    end

    def log_failure(error, context)
      Rails.logger.error("[Drawings::EnterLead] failed #{context}: #{error.class}: #{error.message}")
    end
  end
end
