# The binary art that the marketplace listing slides are built from, base64
# data-URI'd for the render.
#
# Same rule as Fonts: nothing is fetched over the network at render time. A
# remote <img> that 404s inside Grover renders an empty box and the PNG still
# comes out looking almost right, so the failure reaches Etsy silently. Reading
# from disk makes the slides hermetic. (The one documented exception is the
# board symbol art inside a page thumbnail, which is loaded from the CDN exactly
# as it is when the product PDF is printed — see RenderPageThumbnails.)
#
# Files live in app/assets/images/printables (read from disk, never served).
# The room scenes were generated once by the speakanyway-printables pipeline
# (src/plugins/aac/scripts/generate-bg-photos.ts) and are vendored here rather
# than regenerated: they cost real money per image and the listings must not
# redesign themselves every time a printable is re-rendered.
#
# brittany-founder.jpg started as a copy of that repo's, but is now Rails' own:
# it was replaced with a wider head-and-shoulders framing that the about slide's
# circle crop actually suits. Don't "resync" it from the printables repo — the
# crop in layouts/listing_image.html.erb is tuned to this file's aspect.
module Boards
  module Printables
    module BrandAssets
      DIR = Rails.root.join("app/assets/images/printables").freeze

      # The NAMES are load-bearing; the order is not. A scene is picked by
      # scoring each name against the board (StablePick), so this list may be
      # reordered or appended to — renaming a scene is what re-skins the boards
      # that had picked it.
      SCENES = %w[
        reading-nook
        kitchen-morning
        therapy-table
        room-green-chairs
      ].freeze

      class << self
        def logo_data_uri
          @logo_data_uri ||= begin
            encoded = Boards::AssetRendering.logo_base64
            encoded && "data:image/png;base64,#{encoded}"
          end
        end

        def founder_photo_data_uri
          @founder_photo_data_uri ||= data_uri(DIR.join("brittany-founder.jpg"), "image/jpeg")
        end

        # Deterministic per board, never random: re-rendering a printable must
        # not hand a live Etsy listing a different background. Same reasoning as
        # the pipeline's pickVariant.
        def scene_data_uri_for(board)
          scene_data_uri(scene_name_for(board))
        end

        def scene_name_for(board)
          StablePick.from(SCENES, salt: "scene", board: board)
        end

        def scene_data_uri(name)
          @scene_data_uris ||= {}
          @scene_data_uris[name] ||= data_uri(DIR.join("scenes", "#{name}.jpg"), "image/jpeg")
        end

        private

        # nil rather than raising: a slide missing its background is still a
        # usable listing image, and a printable that can't render its gallery at
        # all is a worse outcome than one that renders plainer than intended.
        def data_uri(path, content_type)
          return nil unless File.exist?(path)

          "data:#{content_type};base64,#{Base64.strict_encode64(path.binread)}"
        end
      end
    end
  end
end
