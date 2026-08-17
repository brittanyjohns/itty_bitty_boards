# Screenshots a board inside SpeakAnyWay's app chrome, for the tablet in the
# "on a device" listing slide.
#
# The slide used to warp a bare printed page onto the glass. It read as a
# photograph of a sheet of paper taped to a tablet: Letter-shaped, letterboxed
# by the screen's own proportions, and carrying no sign that the thing on screen
# talks. This wraps the same board in the app's own header — board name, nav,
# speech bar, play/clear/download — so the slide shows the product a buyer
# reaches by scanning the QR.
#
# Ported from speakanyway-printables' renderContentAppPage
# (src/generator/steps/11-render-previews.ts). Same chrome, same shell geometry,
# same fits-vs-clips rule, so a listing from either source shows one app.
#
# Grover work: Sidekiq only, never a request thread.
module Boards
  module Printables
    class RenderDeviceScreen
      # A homography maps the shell onto the screen quad WHATEVER shape either
      # is, so a shell that doesn't match the quad's proportions doesn't fail —
      # it silently ships a stretched board, which a buyer reads as "the product
      # is distorted". The shell is therefore sized from the scene it is going
      # onto, at roughly constant total pixels.
      #
      # This used to be a fixed 1100x720 (≈1.528), the mean of the only two
      # scenes that existed. Every scene added since is a real photograph of a
      # real tablet, and those are 4:3 — so a fixed shell was one scene away
      # from being wrong for most of the library.
      SHELL_AREA = 1100 * 720
      DEFAULT_ASPECT = 1100.0 / 720

      # Kept for the scene guard spec, which asserts a scene's screen is
      # something this class can actually fill.
      SHELL_WIDTH = 1100
      SHELL_HEIGHT = 720

      # 2x, matching the slide it is composited into — the tablet fills most of
      # a 1280px square, so a 1x screen render is visibly soft.
      SCALE = 2

      # Chrome block: 20px top padding + title (27px at 1.1) + 15px margin +
      # the 66px control row + 16px bottom padding + 1px border. Duplicated from
      # layouts/device_screen.html.erb because the centre-vs-clip decision has
      # to be made before the page is rendered, and only ever used for that — a
      # few px of drift here is cosmetic.
      CHROME_HEIGHT = 148
      BODY_PADDING = 14

      # `thumbnail` is a RenderPageThumbnails::Thumbnail of a HEADER-LESS page
      # (Boards::RenderAssetData::HEADER_NONE). A page carrying the print header
      # would put the scan-me band and its QR on the screen, which is the exact
      # tell this slide exists to remove.
      # `scene` is the TabletScene this screen will be warped onto, and is what
      # the shell takes its proportions from. Optional: the video's outro stages
      # the app chrome on a flat card with no tablet behind it, and there the
      # default shape is the right one.
      def initialize(title:, thumbnail:, scene: nil)
        @title = title
        @thumbnail = thumbnail
        @scene = scene
      end

      # The shell's pixel size for this scene: the quad's aspect, at the same
      # total area the fixed shell used, rounded to even numbers so the 2x
      # render lands on whole pixels.
      def shell_width
        @shell_width ||= (Math.sqrt(SHELL_AREA * aspect) / 2).round * 2
      end

      def shell_height
        @shell_height ||= (Math.sqrt(SHELL_AREA / aspect) / 2).round * 2
      end

      # => a PNG data URI, or nil when there is no board render to stage. nil
      # rather than raising: the slide falls back to an empty tablet, which is
      # a plainer image, not a broken gallery.
      def call
        return nil unless thumbnail&.data_uri.present?

        html = ApplicationController.render(
          template: "api/board_printables/device_screen",
          layout: "device_screen",
          assigns: {
            title: title,
            board_data_uri: thumbnail.data_uri,
            fits: fits?,
          },
          formats: [:html],
        )

        png = Grover.new(
          html,
          viewport: { width: shell_width, height: shell_height, device_scale_factor: SCALE },
          full_page: false,
          print_background: true,
        ).to_png

        "data:image/png;base64,#{Base64.strict_encode64(png)}"
      rescue StandardError => e
        Rails.logger.warn("[RenderDeviceScreen] skipped: #{e.class}: #{e.message}")
        nil
      end

      private

      attr_reader :title, :thumbnail, :scene

      def aspect
        return DEFAULT_ASPECT if scene.nil?

        ratio = scene.screen_width.to_f / scene.screen_height
        ratio.positive? && ratio.finite? ? ratio : DEFAULT_ASPECT
      end

      # Does the board, drawn at full width, still fit under the chrome? A wide,
      # short board does and gets centred; anything taller runs past the bottom
      # and is clipped there, which is what a real screen with more board below
      # the fold looks like.
      def fits?
        return true unless thumbnail.width.to_i.positive? && thumbnail.height.to_i.positive?

        body_width = shell_width - (BODY_PADDING * 2)
        body_height = shell_height - CHROME_HEIGHT - BODY_PADDING

        (thumbnail.width.to_f / thumbnail.height) >= (body_width.to_f / body_height)
      end
    end
  end
end
