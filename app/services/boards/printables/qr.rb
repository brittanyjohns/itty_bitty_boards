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

      def self.data_url_for(url)
        png = RQRCode::QRCode.new(url).as_png(
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
