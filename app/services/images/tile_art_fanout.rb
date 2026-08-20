module Images
  # THE single place a change to a shared library Image is allowed to reach
  # existing BoardImages.
  #
  # `images` and `docs` are shared library rows: one "apple" Image is on
  # thousands of boards belonging to unrelated accounts. `board_images
  # .display_image_url` is the opposite — per-tile user content on one user's
  # board. Before this class existed, `Image#update_board_images_display_image`
  # swept EVERY board_image of an Image with no ownership check at all, so an
  # admin picking different art in the library repainted every user's board.
  #
  # The rule, in full:
  #
  #   A tile's picture belongs to the board's owner. A write that originates on
  #   a shared library Image (rather than on a specific board being edited) may
  #   touch a tile only when all of:
  #     1. the tile's board is owned by the ACTING user, or by
  #        User::DEFAULT_ADMIN_ID. No actor => admin-owned boards only.
  #     2. the tile has no picture of its own: display_image_url is nil, or is
  #        exactly the URL being replaced (it was still tracking the old
  #        default). A tile pointing anywhere else was deliberately chosen.
  #     3. the tile is not picture-hidden (the "" marker).
  #
  # A library change may improve what a board's EMPTY tiles fall back to. It may
  # never repaint a tile someone chose. Users opt into improved library art
  # explicitly, per board, via PUT /api/boards/:id/update_to_default_docs —
  # pull, not push.
  #
  # No "pinned" column is needed and none should be added: a non-nil
  # display_image_url IS the pin. That keeps the three-state nil / "" / url
  # model (see BoardImage#picture_hidden?) intact.
  class TileArtFanout
    attr_reader :image, :url, :actor_id, :replacing, :force, :repair_dead

    # url         - the URL to point tiles at.
    # actor:      - User or user id whose action this is. nil means "no actor",
    #               which reaches admin-owned boards ONLY — never a guess.
    # replacing:  - a tile still showing this URL was tracking the old library
    #               default and may be moved.
    # force:      - "apply to all MY boards", including tiles I had pinned.
    #               Relaxes rule 2 only. NEVER rule 1 or 3.
    # repair_dead: - a tile whose URL no longer resolves may be repaired even on
    #               someone else's board: broken art is broken for its owner
    #               too, so fixing it is not repainting a choice.
    def initialize(image, url:, actor: nil, replacing: nil, force: false, repair_dead: false)
      @image = image
      @url = url
      @actor_id = actor.respond_to?(:id) ? actor.id : actor
      @replacing = replacing
      @force = force
      @repair_dead = repair_dead
    end

    def self.call(image, **kwargs)
      new(image, **kwargs).call
    end

    # Returns the ids of the tiles that were repointed.
    def call
      return [] if url.blank?

      updated = []
      image.board_images.includes(:board).find_each do |board_image|
        next unless writable?(board_image)
        next if board_image.display_image_url == url

        board_image.update_column(:display_image_url, url)
        updated << board_image.id
      end
      updated
    end

    # Clearing a tile back to "no picture of its own" is a fan-out too, and
    # obeys exactly the same three rules. nil and not "": nil falls through to
    # the shared Image's art, which is the normal state — "" would switch the
    # picture OFF (BoardImage#unhide_picture! documents the same distinction).
    def self.clear(image, actor: nil)
      actor_id = actor.respond_to?(:id) ? actor.id : actor
      fanout = new(image, url: nil, actor: actor_id)

      cleared = []
      image.board_images.includes(:board).find_each do |board_image|
        next if board_image.picture_hidden?
        next unless fanout.send(:actor_owns?, board_image)
        next if board_image.display_image_url.nil?

        board_image.update_column(:display_image_url, nil)
        cleared << board_image.id
      end
      cleared
    end

    private

    def writable?(board_image)
      # Rule 3 first, and absolutely. `.blank?`/`.present?` both mis-handle ""
      # (it is blank AND not present), which is exactly how the old code
      # un-hid deliberately blanked tiles. Ask the model, never a bare test.
      return false if board_image.picture_hidden?

      unless actor_owns?(board_image)
        # Out of scope. The only thing that may still reach this tile is an
        # UNATTRIBUTED repair of art that is genuinely broken — an operator
        # cleaning up after destroying the doc the tile pointed at. A named
        # actor never crosses into someone else's board, and the ownership
        # test comes first so a scoped sweep pays for no HEAD requests it
        # cannot act on (a popular label has hundreds of placements).
        return actor_id.nil? && dead?(board_image)
      end

      return true if board_image.display_image_url.nil?
      return true if replacing.present? && board_image.display_image_url == replacing
      return true if dead?(board_image)

      force
    end

    def actor_owns?(board_image)
      owner_id = board_image.board&.user_id
      return false if owner_id.nil?
      return true if owner_id == User::DEFAULT_ADMIN_ID

      actor_id.present? && owner_id == actor_id
    end

    # A HEAD request per tile, so it only runs when a caller explicitly asked to
    # repair. A freshly minted URL is known-good and is never re-validated.
    def dead?(board_image)
      return false unless repair_dead
      return false if board_image.display_image_url.blank?

      !image.authorized_to_view_url?(board_image.display_image_url)
    end
  end
end
