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

      # Purge the existing attachment synchronously so the S3 object at the
      # deterministic key is removed before we PUT the new one. Without this,
      # `create_and_upload!` would hit the unique index on active_storage_blobs.key.
      board.preview_image.purge if board.preview_image.attached?

      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(png_data),
        filename: "#{board.slug}-preview.png",
        content_type: "image/png",
        key: stable_preview_key,
      )
      board.preview_image.attach(blob)
    end

    # Deterministic per-board key so the public CDN URL never changes across
    # regenerations. Stale-URL chasing in callers becomes unnecessary; clients
    # cache-bust on the `?v=<updated_at>` query string emitted by
    # Board#preview_image_url.
    def stable_preview_key
      "board_previews/#{board.id}/preview.png"
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
