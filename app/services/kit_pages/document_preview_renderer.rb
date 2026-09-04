# ruby-vips arrives as an image_processing dependency and is otherwise loaded
# lazily, so `defined?(Vips)` is false until something has asked for it — which
# would make `available?` below answer "no PDF loader" on a host that has one.
begin
  require "vips"
rescue LoadError => e
  Rails.logger.warn("[DocumentPreviewRenderer] ruby-vips unavailable: #{e.message}")
end

module KitPages
  # Rasterizes the first pages of an uploaded PDF into PNGs, so a kit page whose
  # download is a hand-uploaded document still shows a visitor what they are
  # about to receive. A printable-backed page gets that from its marketplace
  # gallery; an uploaded one has nothing else to show.
  #
  # Uses **libvips**, which is already the Active Storage variant processor in
  # production and links libpoppler on the platforms we deploy — so this needs
  # no new gem and no new binary. Deliberately not poppler's `pdftoppm` or
  # ImageMagick directly: Boards::Printables::RenderPageThumbnails records that
  # neither can be relied on in the deploy image, which is exactly why
  # everything here is gated on `available?` and fails soft.
  #
  # Failing soft is the whole contract. A landing page with no mockups is a
  # worse page; a landing page that 500s on upload is a broken one. Every path
  # returns [] and logs.
  class DocumentPreviewRenderer
    # Enough to read on a landing page at ~2x its rendered width without
    # producing a multi-megabyte PNG per page.
    PREVIEW_DPI = 150

    class << self
      # True only when this libvips was built with PDF support. Memoized per
      # process — the answer can't change without a restart.
      def available?
        return @available unless @available.nil?

        @available = pdf_loader?
      end

      # Test seam: `available?` memoizes.
      def reset_availability!
        @available = nil
      end

      private

      def pdf_loader?
        defined?(Vips) && Vips.type_find("VipsOperation", "pdfload_buffer") != 0
      rescue StandardError => e
        Rails.logger.warn("[DocumentPreviewRenderer] no PDF loader: #{e.class}: #{e.message}")
        false
      end
    end

    # A default keyword argument is evaluated on every `new`, so the limit is
    # genuinely read at call time rather than frozen into the class.
    def initialize(pages: KitPage.preview_render_limit)
      @pages = pages.to_i
    end

    # Yields one PNG at a time so the caller can attach and release it. The
    # array form below holds every page in memory at once, which is nothing at
    # two pages and 50-150 MB in one Sidekiq worker at five documents of ten
    # 150-DPI letter pages.
    #
    # A page that fails to render is skipped, never yielded as nil.
    def each_page(bytes)
      return unless self.class.available?
      return if bytes.blank? || @pages < 1

      count = [page_count(bytes), @pages].min
      return if count < 1

      (0...count).each do |index|
        png = render_page(bytes, index)
        yield(png, index) if png
      end
    end

    # => [png_bytes, ...] for the first `pages` pages of the document, or [].
    def call(bytes)
      [].tap { |pages| each_page(bytes) { |png, _index| pages << png } }
    end

    private

    # libvips reports the document's page count on the first page's header.
    # A file it can't open at all is not a PDF we can preview — treat it the
    # same as one with no pages rather than letting the error escape.
    def page_count(bytes)
      Vips::Image.pdfload_buffer(bytes).get("pdf-n_pages").to_i
    rescue StandardError => e
      Rails.logger.warn("[DocumentPreviewRenderer] could not read page count: #{e.class}: #{e.message}")
      0
    end

    # One bad page costs that page and nothing else — the rest of the gallery is
    # still worth showing.
    def render_page(bytes, index)
      Vips::Image
        .pdfload_buffer(bytes, page: index, dpi: PREVIEW_DPI)
        .write_to_buffer(".png")
    rescue StandardError => e
      Rails.logger.warn("[DocumentPreviewRenderer] page #{index} failed: #{e.class}: #{e.message}")
      nil
    end
  end
end
