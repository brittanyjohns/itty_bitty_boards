# app/services/communicators/generate_safety_id_card.rb
module Communicators
  class GenerateSafetyIdCard < BaseAssetGenerator
    # Bump when the TEMPLATE or LAYOUT changes in a way that should reach cards
    # already generated. `safety_info_signature` only moves when the PROFILE
    # does (avatar + settings), so without this a rendering fix reaches new
    # cards only and every existing attachment keeps its old bytes forever —
    # the gap GenerateCarePlan::LAYOUT_VERSION names and this card had.
    # 1: the card as it stood when the version was introduced.
    # 2: an unanswered medical field is omitted and named in one muted line
    #    rather than printed as a negative finding (#890). This is the bump
    #    that reaches a card already laminated onto a backpack.
    LAYOUT_VERSION = 2

    PNG_WIDTH = 1200
    PNG_HEIGHT = 1800

    def self.call(profile, regenerate: false, qr_target_url: nil)
      new(profile, qr_target_url: qr_target_url).call(regenerate: regenerate)
    end

    def call(regenerate: false)
      signature = asset_signature("#{profile.safety_info_signature}::v#{LAYOUT_VERSION}")

      unless regenerate
        if attached_and_fresh?(:safety_id_png, signature: signature) &&
           attached_and_fresh?(:safety_id_pdf, signature: signature)
          return profile
        end
      end

      html = rendered_html(
        template: "communicators/assets/safety_id_card",
        locals: template_locals,
      )

      png = generate_png_from_html(html, width: PNG_WIDTH, height: PNG_HEIGHT)
      pdf = generate_pdf_from_html(html, width: PNG_WIDTH, height: PNG_HEIGHT)

      attach_binary(
        record: profile,
        attachment_name: :safety_id_png,
        bytes: png,
        filename: "safety-id-card-#{profile.id}.png",
        content_type: "image/png",
        metadata: { signature: signature },
      )

      attach_binary(
        record: profile,
        attachment_name: :safety_id_pdf,
        bytes: pdf,
        filename: "safety-id-card-#{profile.id}.pdf",
        content_type: "application/pdf",
        metadata: { signature: signature },
      )

      profile
    end

    private

    # The medical grid's per-block accent, keyed by field. The block's heading
    # is `text-transform:uppercase`, so the label can come from the shared
    # document (sentence case) without changing how the card reads.
    FIELD_ACCENTS = {
      "allergies" => "#7c3aed",
      "medical_conditions" => "#2563eb",
      "medications" => "#0f766e",
      "other_conditions" => "#ea580c",
    }.freeze

    def template_locals
      settings = profile.settings || {}
      {
        profile: profile,
        avatar_data_url: avatar_data_url,
        # `permanent_url` — printed card, same rule as the device tag: the QR
        # must survive the owner changing or revoking their public link.
        qr_data_url: qr_data_url_for(effective_qr_url(profile.permanent_url)),
        logo: logo_base64,
        display_name: profile.safety_display_name,
        # Not a medical field: an unanswered note falls back to an INSTRUCTION,
        # which asserts nothing about the person. That is why `emergency_notes`
        # is excluded from the omit-and-name rule below — the card did print
        # something here, so naming "notes" as unanswered would be wrong.
        emergency_notes: settings["emergency_notes"].presence || "Please call my emergency contacts.",
        medical_fields: medical_fields,
        blank_medical_fields_note: document.blank_emergency_fields_note(
          only: CarePlanDocument::MEDICAL_EMERGENCY_FIELDS,
        ),
        contacts: profile.safety_contacts,
      }
    end

    # An unanswered medical field is OMITTED and named in one muted line, the
    # rule CarePlanDocument already settled for the care plan. It used to print
    # "None listed" at 25px under its own coloured heading, which on a card a
    # stranger reads in seconds does not say "unanswered" — it says a negative
    # finding was recorded. Every communicator created through the MySpeak
    # wizard has all four of these empty, so that was the DEFAULT card.
    def medical_fields
      document.emergency_fields(only: CarePlanDocument::MEDICAL_EMERGENCY_FIELDS).map do |field|
        {
          label: field.label,
          value: field.values.first,
          accent: FIELD_ACCENTS.fetch(field.key, "#7c3aed"),
        }
      end
    end

    def document
      @document ||= CarePlanDocument.new(profile)
    end
  end
end
