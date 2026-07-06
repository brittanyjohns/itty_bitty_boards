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

    def qr_data_url(url, size: 300)
      return nil if url.blank?

      png = RQRCode::QRCode.new(url).as_png(
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
