# The QR code that points a buyer (or a parent holding a photocopy) back at the
# live board.
#
# Extracted from RenderWrappers so the printed cover and the marketplace slides
# can't drift apart. They encode the same URL for the same board, and the two
# most obvious ways to get that subtly wrong — a different target, or a
# different fill that kills scan contrast — both stop being possible when
# there's one implementation.
module Boards
  module Printables
    module Qr
      # Navy at 400px, on WHITE — the pipeline fills its QR with cream to melt
      # into a cream page, but ours sits inside a white card in both the colour
      # and ink-light variants, where a cream fill prints as a visible square
      # inside the card. White also maximises scan contrast, which is the whole
      # job of this image.
      DARK = "#13496f".freeze
      LIGHT = "#FFFFFF".freeze
      SIZE = 400

      # The URL a QR for this board should point at: /pb/<slug-or-id>. Shared
      # with RenderWrappers' printed text version of the same link.
      def self.target_url_for(board)
        "#{CollectPages::QR_BASE_URL}/#{CollectPages.qr_key_for(board)}"
      end

      # The marketplace gallery/video QRs carry campaign tags; the PRINTED ones
      # never do. A tagged /pb/ URL is ~148 chars, a version-12 (65-module)
      # code — 0.31mm per module at the printed page's 0.8in, half the ~0.5mm
      # phone-camera floor that already broke the kit tags once (see
      # .claude-notes/marketing-assets.md). A slide QR is only ever scanned off
      # a screen at 244px+, where the extra modules cost nothing.
      LISTING_UTM = {
        utm_source: "etsy",
        utm_medium: "listing",
        utm_campaign: "board_printable",
      }.freeze

      # `content` names the surface the code was scanned from — a gallery image
      # or a frame of the listing video.
      def self.listing_target_url_for(board, content:)
        query = LISTING_UTM.merge(utm_content: content).to_query
        "#{target_url_for(board)}?#{query}"
      end

      # ECC. Print keeps rqrcode's :h default — paper gets creased, folded and
      # photocopied, and the printed URL is short enough to afford it. A slide
      # QR encodes the longer tagged URL and is only ever read off a clean
      # screen, so it trades damage redundancy for modules: :h renders the
      # tagged URL as a version-12 (65-module) code, ~3.7px per module in the
      # 244px frame slot, which is thin once Etsy re-encodes the video. :m is
      # version 8 (49 modules, ~5px).
      PRINT_ECC = :h
      SCREEN_ECC = :m

      def self.data_url_for(url, level: PRINT_ECC)
        png = RQRCode::QRCode.new(url, level: level).as_png(
          bit_depth: 8,
          border_modules: 0,
          color_mode: ChunkyPNG::COLOR_TRUECOLOR,
          color: DARK,
          fill: LIGHT,
          size: SIZE,
        )
        "data:image/png;base64,#{Base64.strict_encode64(png.to_s)}"
      end
    end
  end
end
