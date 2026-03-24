# app/services/communicators/generate_device_tag.rb
module Communicators
  class GenerateDeviceTag < BaseAssetGenerator
    PNG_WIDTH = 1200
    PNG_HEIGHT = 700

    def self.call(profile, regenerate: false)
      new(profile).call(regenerate: regenerate)
    end

    def call(regenerate: false)
      signature = profile.safety_info_signature

      unless regenerate
        if attached_and_fresh?(:device_tag_png, signature: signature) &&
           attached_and_fresh?(:device_tag_pdf, signature: signature)
          return profile
        end
      end

      html = rendered_html(
        template: "communicators/assets/device_tag",
        locals: template_locals,
      )

      png = generate_png_from_html(html, width: PNG_WIDTH, height: PNG_HEIGHT)
      pdf = generate_pdf_from_html(html, width: PNG_WIDTH, height: PNG_HEIGHT)

      attach_binary(
        record: profile,
        attachment_name: :device_tag_png,
        bytes: png,
        filename: "device-tag-#{profile.id}.png",
        content_type: "image/png",
        metadata: { signature: signature },
      )

      attach_binary(
        record: profile,
        attachment_name: :device_tag_pdf,
        bytes: pdf,
        filename: "device-tag-#{profile.id}.pdf",
        content_type: "application/pdf",
        metadata: { signature: signature },
      )

      profile
    end

    private

    def template_locals
      settings = profile.settings || {}
      primary_contact = profile.safety_contacts.first || {}

      {
        profile: profile,
        avatar_data_url: avatar_data_url,
        logo: logo_base64,
        qr_data_url: qr_data_url_for(profile.public_url),
        display_name: profile.device_tag_display_name,
        device_notes: settings["device_notes"].presence || "This device is my voice. Please use it to help me communicate and access important information in any situation.",
        primary_contact_name: primary_contact["name"].presence || "Emergency Contact",
        primary_contact_phone: primary_contact["phone"].presence || "No phone listed",
      }
    end
  end
end
