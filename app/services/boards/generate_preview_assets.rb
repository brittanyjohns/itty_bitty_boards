# app/services/boards/generate_preview_assets.rb
module Boards
  class GeneratePreviewAssets
    def initialize(board:, screen_size: "lg", hide_colors: false, hide_header: false, routes:)
      @board = board
      @screen_size = screen_size
      @hide_colors = hide_colors
      @hide_header = hide_header
      @routes = routes
    end

    def call(generate_png: true, generate_pdf: false)
      if generate_png
        attach_png
        # Refresh the denormalized snapshot to the *current* preview URL in the
        # same operation that produced the PNG. Doing it here (rather than in a
        # post-job reload step) closes the window where a fetch between attach
        # and write saw the old snapshot, and makes the synchronous callers
        # (Board#generate_previews) keep the snapshot fresh too.
        board.update_preset_display_image_url(board.preview_image_url) if board.preview_image.attached?
      end
      attach_pdf if generate_pdf
    end

    private

    attr_reader :board, :screen_size, :hide_colors, :hide_header, :routes

    def render_data
      @render_data ||= Boards::RenderAssetData.new(
        board: board,
        screen_size: screen_size,
        hide_colors: hide_colors,
        hide_header: hide_header,
        routes: routes,
      ).call
    end

    def html
      @html ||= ApplicationController.render(
        template: "api/boards/print",
        layout: "pdf",
        assigns: render_data,
        formats: [:html],
      )
    end

    def grover_options
      landscape = render_data[:landscape]

      {
        format: "Letter",
        landscape: landscape,
        viewport: {
          width: landscape ? 792 : 612,
          height: landscape ? 612 : 792,
        },
        full_page: false,
        prefer_css_page_size: true,
        print_background: true,
      }
    end

    def attach_png
      png_data = Grover.new(html, **grover_options).to_png

      # Purge the superseded attachment (and its S3 object) before uploading the
      # replacement, so old previews don't accumulate in the bucket.
      board.preview_image.purge if board.preview_image.attached?

      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(png_data),
        filename: "#{board.slug}-preview.png",
        content_type: "image/png",
        key: versioned_preview_key,
      )
      board.preview_image.attach(blob)
    end

    # A NEW key — and therefore a new CDN path — for every regeneration.
    #
    # This deliberately is NOT one stable key per board. The CloudFront
    # distribution in front of the bucket does not include the query string in
    # its cache key, so the `?v=<blob.created_at>` buster on
    # Board#preview_image_url invalidates nothing: after the first generation
    # warmed the edge, every later regeneration wrote fresh bytes to a key whose
    # cached copy kept being served. Covers appeared to update ("Cover updated
    # from your board") while the picture never changed, intermittently, because
    # edge servers cache independently.
    #
    # Callers can safely depend on a changing path: display_image_url /
    # preview_image_url resolve live from the attachment, and the denormalized
    # settings["preset_display_image_url"] is refreshed in #call, in the same
    # operation that produced the PNG.
    def versioned_preview_key
      "board_previews/#{board.id}/#{Time.current.to_i}-#{SecureRandom.hex(4)}/preview.png"
    end

    def attach_pdf
      pdf_data = Grover.new(html, **grover_options).to_pdf

      board.pdf_file.purge if board.pdf_file.attached?

      board.pdf_file.attach(
        io: StringIO.new(pdf_data),
        filename: "#{board.slug}.pdf",
        content_type: "application/pdf",
      )
    end
  end
end
