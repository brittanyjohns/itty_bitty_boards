module Boards
  class BoardPdfLayoutNormalizer
    def self.call(board, screen_size)
      new(board, screen_size).call
    end

    def initialize(board, screen_size)
      @board = board
      @screen_size = screen_size
    end

    def call
      @board_tiles = board_tiles(screen_size) || []

      @board_tiles.map do |t|
        {
          "x" => t["x"] || t[:x] || 0,
          "y" => t["y"] || t[:y] || 0,
          "w" => t["w"] || t[:w] || 1,
          "h" => t["h"] || t[:h] || 1,
          "label" => t["label"] || t[:label] || "",
          "image_url" => t["image_url"] || t[:image_url],
          "bg_color" => t["bg_color"] || t[:bg_color] || "#FFFFFF",
          "border_color" => t["border_color"] || t[:border_color] || "#000000",
          "border_width" => t["border_width"] || t[:border_width] || 0,
          "border_radius" => t["border_radius"] || t[:border_radius] || 0,
          "hide_label" => t["hide_label"] || t[:hide_label] || false,
          "i" => t["i"] || t[:i] || "",
        }
      end
    end

    def board_tiles(screen_size = "lg")
      layout_key = screen_size.to_s
      if @board.respond_to?(:board_images) && @board.board_images.any?
        @board.board_images.map do |bi|
          layout = bi.layout[layout_key] || bi.layout["lg"] || {}
          {
            "x" => layout["x"] || 0,
            "y" => layout["y"] || 0,
            "w" => layout["w"] || 1,
            "h" => layout["h"] || 1,
            "label" => bi.display_label || bi.label || "",
            "image_url" => tile_display_src(bi),
            "bg_color" => bi.bg_color || "#FFFFFF",
            "border_color" => bi.border_color || "#000000",
            "border_width" => bi.border_width || 0,
            "border_radius" => bi.border_radius || 0,
            "hide_label" => bi.data&.dig("hide_label") || false,
            "i" => bi.id.to_s,
          }
        end
      else
        []
      end
    end

    private

    # Resolve the tile picture the SAME way the live board JSON does
    # (Board#api_view_with_predictive_images:
    #   board_image.display_image_url || image.display_image_url || image.src_url).
    # We deliberately do NOT use BoardImage#tile_image_url here: its final
    # fallback borrows any same-label admin/public image's src_url, which
    # fabricated a picture on label-only tiles (e.g. an "I feel" header) that
    # the app renders as text. A blank result lets the print template draw the
    # label via generate_placeholder_image, matching what the user sees on screen.
    def tile_display_src(board_image)
      board_image.display_image_url.presence ||
        board_image.image&.display_image_url(@current_user).presence ||
        board_image.image&.src_url.presence
    end

    attr_reader :board, :screen_size
  end
end
