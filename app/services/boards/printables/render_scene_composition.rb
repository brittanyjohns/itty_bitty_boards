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
          },
          formats: [:html],
        )

        jpeg = Grover.new(
          html,
          viewport: { width: CANVAS_WIDTH, height: canvas_height, device_scale_factor: SCALE },
          full_page: false,
          print_background: true,
          quality: JPEG_QUALITY,
        ).to_jpeg

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

      def art_for(slot, entry)
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
