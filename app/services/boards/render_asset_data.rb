# app/services/boards/render_asset_data.rb
module Boards
  class RenderAssetData
    def initialize(board:, screen_size: "lg", hide_colors: false, hide_header: false, routes:)
      @board = board
      @screen_size = screen_size
      @hide_colors = hide_colors
      @hide_header = hide_header
      @routes = routes
    end

    def call
      qr_target_url = AssetRendering.qr_target_url_for(board, routes: routes)
      tiles = normalized_tiles
      columns = resolved_columns
      rows = resolved_rows(tiles)
      landscape = resolved_landscape(rows, columns, tiles.size)

      board_render_width_mm, board_render_height_mm =
        fitted_board_dimensions_mm(columns: columns, rows: rows, landscape: landscape)

      {
        board: board,
        qr_target_url: qr_target_url,
        qr_data_url: AssetRendering.qr_data_url_for(qr_target_url, size: 480),
        screen_size: screen_size,
        hide_colors: hide_colors,
        hide_header: hide_header,
        columns: columns,
        rows: rows,
        tiles: tiles,
        num_of_words: tiles.size,
        landscape: landscape,
        logo: AssetRendering.logo_base64,
        board_title: AssetRendering.board_title_for(board),
        board_render_width_mm: board_render_width_mm,
        board_render_height_mm: board_render_height_mm,
        board_expires_at: board.generated_token_expires_at,
      }
    end

    private

    attr_reader :board, :screen_size, :hide_colors, :hide_header, :routes

    def normalized_tiles
      # Replace this with your real logic if normalize_tiles lives elsewhere
      BoardPdfLayoutNormalizer.call(board, screen_size)
    end

    def resolved_columns
      value = board.columns_for_screen_size(screen_size).to_i
      value.positive? ? value : 1
    end

    def resolved_rows(tiles)
      value = tiles.map { |t| t["y"].to_i + t["h"].to_i }.max || 1
      value.positive? ? value : 1
    end

    def resolved_landscape(rows, columns, num_tiles)
      return true if num_tiles >= 6

      rows > columns
    end

    def fitted_board_dimensions_mm(columns:, rows:, landscape:)
      page_width_mm = landscape ? 279.4 : 215.9
      page_height_mm = landscape ? 215.9 : 279.4

      outer_padding_mm = 6.0
      header_height_mm = hide_header ? 0 : (landscape ? 30.0 : 34.0)
      footer_buffer_mm = 2.0

      available_width_mm = page_width_mm - outer_padding_mm
      available_height_mm = page_height_mm - outer_padding_mm - header_height_mm - footer_buffer_mm

      board_ratio = columns.to_f / rows.to_f

      width_limited_height = available_width_mm / board_ratio
      height_limited_width = available_height_mm * board_ratio

      if width_limited_height <= available_height_mm
        [available_width_mm, width_limited_height]
      else
        [height_limited_width, available_height_mm]
      end
    end
  end
end
