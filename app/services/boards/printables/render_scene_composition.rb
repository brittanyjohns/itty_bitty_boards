# Renders a SceneComposition to a JPEG: the template's base image, each filled
# slot's REAL art warped onto its quad, then the front layer on top — so a ring,
# a clip or a hand in the photo covers the art the way it would in life.
#
# The warp is a CSS matrix3d (SceneSlot, Homography) and the screenshot is the
# same Grover call every listing slide makes. Nothing here is sent to an image
# model: the art is this app's own page renders, its own app-chrome screenshot,
# or a picture an admin uploaded.
#
# The output keeps the TEMPLATE's aspect — 1200 CSS px wide at 2x — rather than
# cropping to a square like the vendored gallery mockups do.
#
# Grover work: Sidekiq only (RenderSceneCompositionJob), never a request thread.
module Boards
  module Printables
    class RenderSceneComposition
      # A render that can't be made as asked. Deterministic, so the job records
      # it for the admin instead of retrying into the same wall.
      class Error < StandardError; end

      CANVAS_WIDTH = 1200
      # MUST be read from inside `viewport`; Grover drops a top-level one.
      SCALE = 2
      JPEG_QUALITY = 90

      # Text slots and overlays are fitted IN the page (layouts/scene_composition
      # + scene/_fit_script): once every face has loaded, each text box steps its
      # font size down from max_px until the words fit, each overlay is scaled
      # into its box, and the script sets this flag. Grover 1.2.3 forwards
      # `wait_for_function` to Puppeteer's page.waitForFunction, so the screenshot
      # is taken only after the fit — never of the pre-fit layout.
      FIT_READY_FUNCTION = "window.__scene_fit === true".freeze
      # A fit is a few dozen layouts. Seconds of waiting means it is stuck, and
      # the render should fail loudly rather than screenshot an unfitted page.
      FIT_TIMEOUT_MS = 15_000

      # Seeds the pre-script font size, so a page whose script never ran still
      # lands close: the average glyph's width in ems (Caveat is condensed) and
      # the line height the layout sets.
      GLYPH_EM = Hash.new(0.56).merge("caveat" => 0.42).freeze
      TEXT_LINE_HEIGHT = 1.2

      # The width an overlay partial lays out at before it is scaled into its
      # box. nil lays out at its content's own width (a single row). The fit
      # script measures the real size; this only seeds the initial scale.
      OVERLAY_LAYOUT_WIDTH = {
        "feature_list" => 560,
        "check_pills" => 640,
        "badges" => nil,
        "steps_row" => nil,
      }.freeze
      OVERLAY_ROW_WIDTH_GUESS = 760

      def initialize(composition:)
        @composition = composition
      end

      # => the JPEG bytes, also attached to composition.render
      def call
        raise Error, "The template has no base image." unless template.base_image.attached?
        raise Error, "The template has no size recorded." unless template.width.to_i.positive? && template.height.to_i.positive?

        # Before rendering, so an edit made while Chrome is busy still reads as
        # stale afterwards.
        digest = composition.current_render_digest

        texts = text_layers
        overlays = overlay_layers
        styled = texts.any? || overlays.any?

        html = ApplicationController.render(
          template: "api/board_printables/scene/composition",
          layout: "scene_composition",
          assigns: {
            width: template.width,
            height: template.height,
            canvas_width: CANVAS_WIDTH,
            canvas_height: canvas_height,
            stage_scale: CANVAS_WIDTH.to_f / template.width,
            base_data_uri: data_uri_for(template.base_image.blob),
            layers: slot_layers,
            front_data_uri: template.front_layer.attached? ? data_uri_for(template.front_layer.blob) : nil,
            text_layers: texts,
            overlay_layers: overlays,
            styled: styled,
          },
          formats: [:html],
        )

        options = {
          viewport: { width: CANVAS_WIDTH, height: canvas_height, device_scale_factor: SCALE },
          full_page: false,
          print_background: true,
          quality: JPEG_QUALITY,
        }
        if styled
          options[:wait_for_function] = FIT_READY_FUNCTION
          options[:wait_for_function_options] = { timeout: FIT_TIMEOUT_MS }
        end

        jpeg = Grover.new(html, **options).to_jpeg

        composition.attach_render!(bytes: jpeg, digest: digest)
        jpeg
      end

      def canvas_height
        (CANVAS_WIDTH * template.height.to_f / template.width).round
      end

      private

      attr_reader :composition

      def template = composition.scene_template

      # One layer per FILLED slot, in the template's slot order. A slot with no
      # entry is left out, so the base image shows through untouched.
      #
      # A filled slot whose art can't be produced raises rather than rendering
      # the bare placeholder: a mockup with a blank sheet where the product
      # should be is a worse listing image than no image.
      def slot_layers
        failures = []

        layers = template.slot_objects.filter_map do |slot|
          entry = composition.slot_art.to_h[slot.key]
          next unless entry

          data_uri = art_for(slot, entry)
          if data_uri.nil?
            failures << (slot.label.presence || slot.key)
            next
          end

          { slot: slot.with_bleed, data_uri: data_uri }
        end

        raise Error, "Couldn't render art for: #{failures.join(", ")}." if failures.any?

        layers
      end

      # One layer per text slot with words to draw, in template order. A slot
      # whose words and default are both blank draws nothing.
      #
      # The words are USER INPUT and reach the page only through ERB's escaping
      # `<%= %>` — never html_safe, never a data URI, never a script string. The
      # look is the template's, re-asserted here because a render must not trust
      # a row that was written around the model.
      def text_layers
        Array(template.text_slots).filter_map do |slot|
          name = slot["label"].presence || slot["key"]
          font = slot["font"]
          raise Error, "Text slot #{name} uses a font the render doesn't carry (#{font.inspect})." unless SceneTemplate::TEXT_FONTS.key?(font)
          raise Error, "Text slot #{name} has an invalid colour." unless slot["color"].to_s.match?(SceneTemplate::TEXT_COLOR_FORMAT)

          text = composition.resolved_text(slot)
          next if text.blank?

          max_chars = slot["max_chars"].to_i
          raise Error, "The text for #{name} is longer than its #{max_chars}-character limit." if text.length > max_chars

          x, y, w, h = slot["box"]
          max_px = slot["max_px"].to_i
          min_px = [slot["min_px"].to_i, max_px].min

          {
            key: slot["key"],
            text: text,
            left: x, top: y, width: w, height: h,
            rotation: slot["rotation"].to_f,
            font: font,
            weight: slot["weight"].to_i,
            color: slot["color"],
            align: SceneTemplate::TEXT_ALIGNS.include?(slot["align"]) ? slot["align"] : "center",
            max_px: max_px,
            min_px: min_px,
            initial_px: estimate_font_px(text, width: w, height: h, min_px: min_px, max_px: max_px, font: font),
          }
        end
      end

      # The largest size, stepping down from max_px, at which the words would
      # wrap into the box by an average-glyph estimate. Only a seed: the fit
      # script measures the real glyphs. It is also what ships if the script
      # never runs, and max_chars bounds how wrong it can be.
      def estimate_font_px(text, width:, height:, min_px:, max_px:, font:)
        em = GLYPH_EM[font]
        max_px.downto(min_px).find do |px|
          per_line = [(width / (px * em)).floor, 1].max
          lines = (text.length.to_f / per_line).ceil
          lines * px * TEXT_LINE_HEIGHT <= height
        end || min_px
      end

      # One layer per overlay region. Every partial renders from GalleryFacts
      # for the composition's printable — there is no free text in an overlay.
      def overlay_layers
        regions = Array(template.overlay_regions)
        return [] if regions.empty?

        facts = composition.overlay_facts
        raise Error, "Overlays need a board printable to take their facts from." unless facts

        regions.map do |region|
          partial = region["partial"]
          raise Error, "Unknown overlay #{partial.inspect}." unless SceneTemplate::OVERLAY_PARTIALS.include?(partial)

          x, y, w, h = region["box"]
          layout_width = OVERLAY_LAYOUT_WIDTH[partial]

          {
            key: region["key"],
            partial: partial,
            left: x, top: y, width: w, height: h,
            layout_width: layout_width,
            initial_scale: (w.to_f / (layout_width || OVERLAY_ROW_WIDTH_GUESS)).round(4),
            locals: overlay_locals(partial, facts),
          }
        end
      end

      def overlay_locals(partial, facts)
        copy = ::Printables::StyledSlideCopy
        case partial
        when "feature_list" then { features: copy.overlay_features(facts) }
        when "badges" then { badges: copy.overlay_badges(facts) }
        when "steps_row" then { steps: copy.overlay_steps(facts) }
        when "check_pills" then { pills: copy.overlay_check_pills(facts) }
        end
      end

      def art_for(slot, entry)
        # Re-asserted here, not only on save: which owner a composition belongs
        # to decides which sources exist for it at all.
        unless composition.allowed_sources.include?(entry["source"])
          raise Error, "#{entry["source"].to_s.humanize} art isn't available for this #{composition.owner_type.underscore.humanize.downcase}."
        end

        case entry["source"]
        when SceneComposition::SOURCE_PAGE_THUMBNAIL
          board = board_for!(entry)
          thumbnails_for(page_pass(entry))[board.id]&.data_uri
        when SceneComposition::SOURCE_DEVICE_SCREEN
          board = board_for!(entry)
          RenderDeviceScreen.new(
            title: Boards::AssetRendering.board_title_for(board),
            thumbnail: thumbnails_for(DEVICE_PASS)[board.id],
            scene: slot.with_bleed,
          ).call
        when SceneComposition::SOURCE_UPLOAD
          data_uri_for(upload_blob_for!(entry))
        when SceneComposition::SOURCE_PRODUCT_ARTWORK
          data_uri_for(product_artwork_blob_for!(entry))
        else
          raise Error, "Unknown art source #{entry["source"].inspect}."
        end
      end

      # Re-asserted at render time, not only on save: a board can leave the
      # printable (a Regenerate re-walks the tree) after the composition was
      # validated, and a render must never reach outside what the owner holds.
      def board_for!(entry)
        board_id = entry["board_id"]
        unless composition.owner_board_ids.include?(board_id)
          raise Error, "Board ##{board_id} isn't part of this printable."
        end

        boards_by_id[board_id] || raise(Error, "Board ##{board_id} no longer exists.")
      end

      def upload_blob_for!(entry)
        attachment = composition.slot_uploads.find { |upload| upload.blob_id == entry["blob_id"] }
        raise Error, "That upload doesn't belong to this composition." unless attachment

        attachment.blob
      end

      # Re-asserted at render time against the owner's artworks as they are NOW:
      # an artwork removed (or a blob id from another product) must never be
      # inlined into this product's mockup.
      def product_artwork_blob_for!(entry)
        blob_id = entry["blob_id"]
        unless composition.owner_artwork_blob_ids.include?(blob_id)
          raise Error, "That artwork doesn't belong to this product."
        end

        ActiveStorage::Blob.find_by(id: blob_id) || raise(Error, "That artwork no longer exists.")
      end

      def boards_by_id
        @boards_by_id ||= Board.where(id: composition.referenced_board_ids & composition.owner_board_ids).index_by(&:id)
      end

      # A thumbnail pass is [hide_colors, hide_header]. The device screen always
      # takes the colour, header-LESS page — a print header on the glass would
      # put a scan-me band and a second QR on the screen.
      DEVICE_PASS = [false, true].freeze

      def page_pass(entry)
        [entry["ink"] == SceneComposition::INK_LOW, entry["header"] == false]
      end

      # Only the passes some slot needs, each covering only the boards that ask
      # for it — every thumbnail is a Grover render.
      def thumbnails_for(pass)
        @thumbnails ||= {}
        @thumbnails[pass] ||= RenderPageThumbnails.new(
          boards: boards_for_pass(pass),
          hide_colors: pass[0],
          hide_header: pass[1],
        ).call
      end

      def boards_for_pass(pass)
        ids = composition.slot_art.to_h.values.filter_map do |entry|
          case entry["source"]
          when SceneComposition::SOURCE_PAGE_THUMBNAIL then entry["board_id"] if page_pass(entry) == pass
          when SceneComposition::SOURCE_DEVICE_SCREEN then entry["board_id"] if pass == DEVICE_PASS
          end
        end

        ids.uniq.filter_map { |id| boards_by_id[id] }
      end

      def data_uri_for(blob)
        "data:#{blob.content_type};base64,#{Base64.strict_encode64(blob.download)}"
      end
    end
  end
end
