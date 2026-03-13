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
          "i" => t["i"] || t[:i] || "",
        }
      end
    end

    def board_tiles(screen_size = "lg")
      layout_key = screen_size.to_s

      if @board.respond_to?(:tiles) && @board.tiles.is_a?(Array)
        @board.tiles
      elsif @board.respond_to?(:board_images) && @board.board_images.any?
        @board.board_images.map do |bi|
          layout = bi.layout[layout_key] || bi.layout["lg"] || {}

          {
            "x" => layout["x"] || 0,
            "y" => layout["y"] || 0,
            "w" => layout["w"] || 1,
            "h" => layout["h"] || 1,
            "label" => bi.label,
            "image_url" => bi.display_image_url_or_default,
            "bg_color" => bi.bg_color || "#FFFFFF",
            "i" => bi.id.to_s,
          }
        end
      else
        []
      end
    end

    private

    attr_reader :board, :screen_size
  end
end
