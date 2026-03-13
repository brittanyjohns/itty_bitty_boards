# app/services/boards/generate_preview_assets.rb
module Boards
  class GeneratePreviewAssets
    def initialize(board:, screen_size: "lg", hide_colors: false, routes:)
      @board = board
      @screen_size = screen_size
      @hide_colors = hide_colors
      @routes = routes
    end

    def call(generate_png: true, generate_pdf: false)
      attach_png if generate_png
      attach_pdf if generate_pdf
    end

    private

    attr_reader :board, :screen_size, :hide_colors, :routes

    def render_data
      @render_data ||= Boards::RenderAssetData.new(
        board: board,
        screen_size: screen_size,
        hide_colors: hide_colors,
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

      board.preview_image.purge if board.preview_image.attached?

      Rails.logger.info "Attaching preview image for board: #{board.id} (#{board.name})"

      board.preview_image.attach(
        io: StringIO.new(png_data),
        filename: "#{board.slug}-preview.png",
        content_type: "image/png",
      )
    end

    def attach_pdf
      pdf_data = Grover.new(html, **grover_options).to_pdf

      board.printable_pdf.purge if board.printable_pdf.attached?

      board.printable_pdf.attach(
        io: StringIO.new(pdf_data),
        filename: "#{board.slug}.pdf",
        content_type: "application/pdf",
      )
    end
  end
end
