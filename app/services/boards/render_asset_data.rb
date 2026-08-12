# app/services/boards/render_asset_data.rb
module Boards
  class RenderAssetData
    # How much of the print header a page carries. Three states rather than two
    # booleans, because "hide the header" and "keep the QR" can contradict each
    # other and the combination that matters most — no title band, code intact —
    # is exactly the one two booleans make ambiguous.
    #
    #   full    — logo, board title, scan-me line and the QR beside them.
    #   qr_only — a small QR alone in the top-right. The board gets nearly the
    #             whole sheet, and the code survives the buyer trimming the band.
    #   none    — nothing. Used for screen mockups and grid thumbnails, where a
    #             printed QR reads as an ad pasted on the glass.
    HEADER_FULL = "full".freeze
    HEADER_QR_ONLY = "qr_only".freeze
    HEADER_NONE = "none".freeze
    HEADER_MODES = [HEADER_FULL, HEADER_QR_ONLY, HEADER_NONE].freeze

    # `hide_header:` is kept for the callers that only ever wanted all-or-
    # nothing (board previews, the print endpoints, grid thumbnails). Pass
    # `header_mode:` to reach the third state; it wins when both are given.
    #
    # `image_load_deadline_ms:` bounds how long the rendered page waits on tile
    # art before falling back to the label placeholder. nil (the default) waits
    # forever, which is what a printable PDF wants — it is a paid artifact and
    # a slow S3 read must not cost it the real symbol. Only the auto preview
    # passes a value: see Boards::GeneratePreviewAssets.
    def initialize(board:, screen_size: "lg", hide_colors: false, hide_header: false, header_mode: nil, routes:, qr_target_url: :default, include_qr: true, image_load_deadline_ms: nil)
      @board = board
      @screen_size = screen_size
      @hide_colors = hide_colors
      @header_mode = resolve_header_mode(header_mode, hide_header)
      @routes = routes
      @qr_target_url_override = qr_target_url
      @include_qr = include_qr
      @image_load_deadline_ms = image_load_deadline_ms
    end

    def call
      qr_target_url = resolved_qr_target_url
      qr_data_url   = qr_target_url.present? ? AssetRendering.qr_data_url_for(qr_target_url, size: 480) : nil
      tiles = normalized_tiles
      columns = resolved_columns
      rows = resolved_rows(tiles)
      landscape = resolved_landscape(rows, columns, tiles.size)

      board_render_width_mm, board_render_height_mm =
        fitted_board_dimensions_mm(columns: columns, rows: rows, landscape: landscape)

      {
        board: board,
        qr_target_url: qr_target_url,
        qr_data_url: qr_data_url,
        screen_size: screen_size,
        hide_colors: hide_colors,
        header_mode: header_mode,
        hide_header: header_mode == HEADER_NONE,
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
        image_load_deadline_ms: image_load_deadline_ms,
      }
    end

    private

    attr_reader :board, :screen_size, :hide_colors, :header_mode, :routes, :image_load_deadline_ms

    def resolve_header_mode(mode, hide_header)
      return hide_header ? HEADER_NONE : HEADER_FULL if mode.blank?

      mode = mode.to_s
      HEADER_MODES.include?(mode) ? mode : HEADER_FULL
    end

    def resolved_qr_target_url
      return nil unless @include_qr

      if @qr_target_url_override == :default
        AssetRendering.qr_target_url_for(board, routes: routes)
      else
        @qr_target_url_override.presence
      end
    end

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

    # The qr_only band reserves room for the code and nothing else — the QR
    # prints at 0.6in there, so 20mm clears it with a little air. Reserving the
    # space rather than floating the QR over the sheet is deliberate: a
    # width-limited board spans the full page, and an overlaid code would land
    # on top of tiles.
    def header_band_height_mm(landscape)
      case header_mode
      when HEADER_NONE then 0
      when HEADER_QR_ONLY then 20.0
      else landscape ? 30.0 : 34.0
      end
    end

    def fitted_board_dimensions_mm(columns:, rows:, landscape:)
      page_width_mm = landscape ? 279.4 : 215.9
      page_height_mm = landscape ? 215.9 : 279.4

      outer_padding_mm = 6.0
      header_height_mm = header_band_height_mm(landscape)
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
