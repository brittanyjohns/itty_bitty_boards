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
      # 1100x720 ≈ 1.528, the mean of the two tablet quad aspects in
      # TabletScene::SCENES (1.50 and 1.55). A homography stretches the artwork
      # onto the quad whatever shape it is, so this ratio is what keeps the
      # board from arriving on the glass squashed. Changing it means re-checking
      # every scene.
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
      def initialize(title:, thumbnail:)
        @title = title
        @thumbnail = thumbnail
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
          viewport: { width: SHELL_WIDTH, height: SHELL_HEIGHT, device_scale_factor: SCALE },
          full_page: false,
          print_background: true,
        ).to_png

        "data:image/png;base64,#{Base64.strict_encode64(png)}"
      rescue StandardError => e
        Rails.logger.warn("[RenderDeviceScreen] skipped: #{e.class}: #{e.message}")
        nil
      end

      private

      attr_reader :title, :thumbnail

      # Does the board, drawn at full width, still fit under the chrome? A wide,
      # short board does and gets centred; anything taller runs past the bottom
      # and is clipped there, which is what a real screen with more board below
      # the fold looks like.
      def fits?
        return true unless thumbnail.width.to_i.positive? && thumbnail.height.to_i.positive?

        body_width = SHELL_WIDTH - (BODY_PADDING * 2)
        body_height = SHELL_HEIGHT - CHROME_HEIGHT - BODY_PADDING

        (thumbnail.width.to_f / thumbnail.height) >= (body_width.to_f / body_height)
      end
    end
  end
end
