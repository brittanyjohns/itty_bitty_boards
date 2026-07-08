require "rqrcode"
require "base64"

module Marketing
  # Shared helpers for the generic (data-less) marketing tag sheets — the
  # compact, print-and-cut backpack tags in the AAC Classroom Kit. Each sheet
  # renders a fixed-physical-size card N-up on a Letter page via Grover, with a
  # shared QR pointing at the marketing funnel. No Profile / no per-child data.
  module SheetRendering
    LETTER_GROVER_OPTIONS = {
      format: "Letter",
      landscape: false,
      viewport: { width: 612, height: 792 },
      full_page: false,
      prefer_css_page_size: true,
      print_background: true,
    }.freeze

    private

    def render_letter_pdf(template:, assigns:)
      html = ApplicationController.render(
        template: template,
        layout: false,
        assigns: assigns,
        formats: [:html],
      )
      Grover.new(html, **LETTER_GROVER_OPTIONS).to_pdf
    end

    # ECC level :m is deliberate. The kit QR target is the SHORT
    # `speakanyway.com/myspeak` funnel URL (no UTM) — ~31 chars, a version-2
    # (25-module) QR. That leaves room to run :m's 15% damage redundancy and
    # still stay a low-density version-3 (29-module) code, which at the tags'
    # printed sizes is ~0.9mm per module — comfortably above the ~0.5mm
    # phone-camera detection floor.
    #
    # History: the tags used to encode the ~119-char /classroom UTM URL, which
    # forced a 41-module (version-6) QR even after ECC was dropped to :l just
    # to fit it — and it still barely scanned at the small printed size (the
    # "QR won't even scan" kit bug). Shortening the URL to /myspeak removed the
    # reason for :l, so we restored damage tolerance. Keep the caller's
    # qr_target_url short; a long URL re-inflates the module count and
    # re-breaks scanning. size: 480 keeps the source ≥300dpi.
    def qr_data_url(url, size: 480)
      return nil if url.blank?

      png = RQRCode::QRCode.new(url, level: :m).as_png(
        size: size,
        border_modules: 4,
        module_px_size: 6,
      )
      "data:image/png;base64,#{Base64.strict_encode64(png.to_s)}"
    end

    def logo_base64
      path = Rails.root.join("public/logo_bubble.png")
      return nil unless File.exist?(path)

      Base64.strict_encode64(File.binread(path))
    end
  end
end
