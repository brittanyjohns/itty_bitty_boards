# app/services/boards/asset_rendering.rb
module Boards
  module AssetRendering
    extend self

    # PROSPECTIVE on purpose: this QR is rendered into a board PDF from the
    # editor, before the board is published, and it has to encode where the
    # board will resolve. `Board#public_url` is nil until publication (#860),
    # so reading it here would silently swap every draft's QR target for the
    # Rails HTML route.
    def qr_target_url_for(board, routes:)
      board.prospective_public_url || routes.board_url(board)
    end

    def qr_data_url_for(url, size: 480)
      qr = RQRCode::QRCode.new(url)
      png = qr.as_png(
        bit_depth: 1,
        border_modules: 4,
        color_mode: ChunkyPNG::COLOR_GRAYSCALE,
        color: "black",
        fill: "white",
        module_px_size: 6,
        size: size,
      )

      "data:image/png;base64,#{Base64.strict_encode64(png.to_s)}"
    end

    def logo_base64(path = Rails.root.join("public/logo_bubble.png"))
      return nil unless File.exist?(path)

      Base64.strict_encode64(File.binread(path))
    end

    def board_title_for(board, max_length: 50)
      raw = board.try(:name).presence || "Communication Board"
      raw.truncate(max_length, omission: "…")
    end
  end
end
