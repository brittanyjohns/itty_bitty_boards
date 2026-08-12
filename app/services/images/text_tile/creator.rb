# Renders a text tile and attaches it to ONE board_image.
#
# Deliberately not ImageHelper#save_image_from_base64, which does three things
# that are wrong here:
#
#   * update_all_boards_image_belongs_to — fans the new URL out to every
#     board_image sharing this Image across all the user's boards. An AI
#     picture of "more" is the same picture everywhere; one board's typography
#     is not, so a text tile must never repaint a sibling board.
#   * image.update!(status: "finished") — the shared Image's generation status
#     has nothing to do with a tile-local render.
#   * `return if Rails.env.test?` — makes the whole path untestable.
#
# The Doc still hangs off the Image (not the BoardImage) so it picks up
# tile_variant/tile_url, shows in that tile's picture gallery, and can be
# re-selected later like any other doc.
module Images
  module TextTile
    module Creator
      module_function

      def call(board_image:, user:, options:)
        png = Renderer.new(options).to_png
        image = board_image.image
        raise ArgumentError, "board_image #{board_image.id} has no image" if image.nil?

        doc = image.docs.create!(
          raw: options.text,
          user_id: user&.id,
          board_id: board_image.board_id,
          source_type: Doc::SOURCE_TYPE_TEXT_TILE,
          data: { "text_image" => options.to_h, "content_type" => "image/png" },
        )

        doc.image.attach(
          io: StringIO.new(png),
          filename: "text_#{image.id}_doc_#{doc.id}.png",
          content_type: "image/png",
        )

        # Force the 288px variant now so the first board load isn't the thing
        # that pays for it — same reason save_image_from_base64 does.
        doc.tile_variant&.processed

        board_image.data = (board_image.data || {}).merge(
          "text_image" => options.to_h.merge("doc_id" => doc.id),
        )
        board_image.data["hide_label"] = options.hide_label
        board_image.update!(status: "complete", display_image_url: doc.tile_url)
        board_image.board&.broadcast_board_update!

        doc
      end
    end
  end
end
