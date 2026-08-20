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
#
# DEDUPE. A text render is deterministic: Options#render_digest is defined as
# everything that changes the pixels and nothing that doesn't, so two tiles
# with the same digest are byte-identical no matter whose board they are on.
# Rendering is the expensive part (a Grover fork spawns node + Chromium, ~1s),
# and the bulk "Set text image" path fires one per selected tile — a 30-tile
# core board used to mean 30 Chrome launches for maybe a dozen distinct
# pictures. So before rendering we look the digest up, in two tiers:
#
#   1. Same Image, same user, same digest — reuse the Doc ROW outright. This is
#      the same picture in the same tile's gallery; a second row would just be
#      a duplicate thumbnail for the user to scroll past.
#   2. Any other Doc with that digest — this Image needs its own Doc row (the
#      row is per-user/per-Image; see docs.current and UserDoc in CLAUDE.md),
#      but it can share the BLOB. No render, no upload.
#
# Sharing one blob across Doc rows is safe: active_storage_attachments has a
# foreign key on blob_id and ActiveStorage::Blob#purge rescues
# InvalidForeignKey, so destroying one Doc can't delete the bytes out from
# under the others. Don't drop that FK.
module Images
  module TextTile
    module Creator
      module_function

      # broadcast: false is for the batch job, which rebroadcasts each board
      # once at the end rather than once per tile.
      def call(board_image:, user:, options:, broadcast: true)
        image = board_image.image
        raise ArgumentError, "board_image #{board_image.id} has no image" if image.nil?

        digest = options.render_digest
        doc = reusable_doc(image, user, digest) || build_doc(board_image, image, user, options, digest)

        apply_to_tile(board_image, doc, options)
        board_image.board&.broadcast_board_update! if broadcast

        doc
      end

      # Tier 1: this Image already carries this exact render for this user.
      def reusable_doc(image, user, digest)
        text_tile_docs(digest)
          .where(documentable_type: "Image", documentable_id: image.id, user_id: user&.id)
          .order(id: :desc)
          .first
      end

      # Tier 2: somebody has rendered these exact pixels before — take the blob.
      def reusable_blob(digest)
        text_tile_docs(digest).order(id: :desc).first&.image&.blob
      end

      # Only docs whose bytes are actually still attached: a row whose blob was
      # purged (the webp conversion rake task does that) is not a source.
      def text_tile_docs(digest)
        Doc
          .joins(:image_attachment)
          .where(source_type: Doc::SOURCE_TYPE_TEXT_TILE)
          .where("docs.data->>'render_digest' = ?", digest)
      end

      def build_doc(board_image, image, user, options, digest)
        blob = reusable_blob(digest)

        doc = image.docs.create!(
          raw: options.text,
          user_id: user&.id,
          board_id: board_image.board_id,
          source_type: Doc::SOURCE_TYPE_TEXT_TILE,
          data: {
            "text_image" => options.to_h,
            "content_type" => blob&.content_type || "image/png",
            "render_digest" => digest,
          },
        )

        if blob
          doc.image.attach(blob)
        else
          doc.image.attach(
            io: StringIO.new(Renderer.new(options).to_png),
            filename: "text_#{image.id}_doc_#{doc.id}.png",
            content_type: "image/png",
          )
        end

        # Force the 288px variant now so the first board load isn't the thing
        # that pays for it — same reason save_image_from_base64 does. Falls
        # back to a queued render if a transaction happens to be open. A shared
        # blob's variant is already processed, so this is a lookup, not work.
        doc.ensure_tile_variant!

        doc
      end

      def apply_to_tile(board_image, doc, options)
        board_image.data = (board_image.data || {}).merge(
          "text_image" => options.to_h.merge("doc_id" => doc.id),
        )
        board_image.data["hide_label"] = options.hide_label
        board_image.update!(status: "complete", display_image_url: doc.tile_url)
      end

      private_class_method :reusable_doc, :reusable_blob, :text_tile_docs, :build_doc, :apply_to_tile
    end
  end
end
