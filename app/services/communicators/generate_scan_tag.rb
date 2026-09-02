# app/services/communicators/generate_scan_tag.rb
module Communicators
  # The simplest of the printed communicator documents: the QR code, one
  # optional line of text, and a small SpeakAnyWay mark. The device tag is a
  # dense card built for the back of a tablet; this one is for a backpack, a
  # wheelchair frame, or a lanyard, where the only job is "scan this".
  class GenerateScanTag < BaseAssetGenerator
    PNG_WIDTH = 800
    PNG_HEIGHT = 800

    def self.call(profile, regenerate: false, qr_target_url: nil)
      new(profile, qr_target_url: qr_target_url).call(regenerate: regenerate)
    end

    def call(regenerate: false)
      signature = asset_signature(profile.safety_info_signature)

      unless regenerate
        if attached_and_fresh?(:scan_tag_png, signature: signature) &&
           attached_and_fresh?(:scan_tag_pdf, signature: signature)
          return profile
        end
      end

      html = rendered_html(
        template: "communicators/assets/scan_tag",
        locals: template_locals,
      )

      png = generate_png_from_html(html, width: PNG_WIDTH, height: PNG_HEIGHT)
      pdf = generate_pdf_from_html(html, width: PNG_WIDTH, height: PNG_HEIGHT)

      attach_binary(
        record: profile,
        attachment_name: :scan_tag_png,
        bytes: png,
        filename: "scan-tag-#{profile.id}.png",
        content_type: "image/png",
        metadata: { signature: signature },
      )

      attach_binary(
        record: profile,
        attachment_name: :scan_tag_pdf,
        bytes: pdf,
        filename: "scan-tag-#{profile.id}.pdf",
        content_type: "application/pdf",
        metadata: { signature: signature },
      )

      profile
    end

    private

    # The note is resolved HERE and never in the template, so there is one
    # default rather than two that can drift apart.
    #
    # Two settings keys, not one: a bare string can't tell "never set" (which
    # wants the default line) from "deliberately cleared" (which wants no line
    # at all), because `.presence` collapses nil and "". `scan_tag_note_enabled`
    # is the on/off answer and defaults to true, so every existing profile keeps
    # printing a line without a backfill.
    def template_locals
      settings = profile.settings || {}
      show_note = settings.fetch("scan_tag_note_enabled", true)

      note =
        if show_note
          settings["scan_tag_note"].presence || Profile::SCAN_TAG_DEFAULT_NOTE
        end

      {
        profile: profile,
        logo: logo_base64,
        # `permanent_url`, never `public_url` — the same rule the device tag
        # follows. This tag is printed and clipped to a bag, so its QR has to
        # keep resolving after the owner rotates or revokes their public link.
        # effective_qr_url keeps the Classroom Kit's override working for free.
        qr_data_url: qr_data_url_for(effective_qr_url(profile.permanent_url)),
        note: note,
      }
    end
  end
end
