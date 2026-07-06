require "rqrcode"
require "base64"

module Marketing
  # Renders the generic AAC Classroom name-tag sheet (variant A from
  # .claude-notes/name-tag-asset-sketch.md): a fillable "Hi! My name is ___"
  # card, N-up on a Letter page, with a shared QR pointing at the marketing
  # funnel. No Profile / no per-child data — it is a blank classroom printable.
  #
  # HTML -> PDF via Grover, same engine as the board and communicator-asset
  # generators. Returns PDF bytes; the caller streams or hosts them.
  class NameTagSheet
    DEFAULT_PER_PAGE = 8 # 2 columns x 4 rows on Letter portrait

    def initialize(qr_target_url: nil, per_page: DEFAULT_PER_PAGE)
      @qr_target_url = qr_target_url.presence
      @per_page = per_page.to_i.positive? ? per_page.to_i : DEFAULT_PER_PAGE
    end

    def to_pdf
      Grover.new(html, **grover_options).to_pdf
    end

    private

    attr_reader :qr_target_url, :per_page

    def html
      ApplicationController.render(
        template: "marketing/name_tag_sheet",
        layout: false,
        assigns: {
          card_count: per_page,
          logo: logo_base64,
          qr_data_url: qr_data_url,
        },
        formats: [:html],
      )
    end

    def grover_options
      {
        format: "Letter",
        landscape: false,
        viewport: { width: 612, height: 792 },
        full_page: false,
        prefer_css_page_size: true,
        print_background: true,
      }
    end

    # Keep in lockstep with Marketing::SheetRendering#qr_data_url — same
    # deliberate ECC :l (rqrcode's default :h makes the long UTM URL too
    # dense to phone-scan at the small printed size; see the note there).
    def qr_data_url
      return nil if qr_target_url.blank?

      png = RQRCode::QRCode.new(qr_target_url, level: :l).as_png(
        size: 480,
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
