# app/services/communicators/generate_safety_id_card.rb
module Communicators
  class GenerateSafetyIdCard < BaseAssetGenerator
    PNG_WIDTH = 1200
    PNG_HEIGHT = 1800

    def self.call(profile, regenerate: false)
      new(profile).call(regenerate: regenerate)
    end

    def call(regenerate: false)
      signature = profile.safety_info_signature

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

    def template_locals
      settings = profile.settings || {}
      {
        profile: profile,
        avatar_data_url: avatar_data_url,
        qr_data_url: qr_data_url_for(profile.public_url),
        logo: logo_base64,
        display_name: profile.safety_display_name,
        emergency_notes: settings["emergency_notes"].presence || "Please call my emergency contacts.",
        allergies: settings["allergies"].presence || "None listed",
        medical_conditions: settings["medical_conditions"].presence || "None listed",
        medications: settings["medications"].presence || "None listed",
        other_conditions: settings["other_conditions"].presence || "None listed",
        contacts: profile.safety_contacts,
      }
    end
  end
end
