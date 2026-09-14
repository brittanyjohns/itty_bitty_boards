module Images
  # The two questions every "fill a tile with art" path asks when a likeness may
  # apply, answered once so the board fill, the Board Builder and the seeded set
  # cloner can't drift apart.
  module LikenessArt
    module_function

    # Does this Image already have art a board owned by `owner_id` would show
    # without generating anything — library art, or the owner's own ordinary
    # art? A likeness doc does NOT count: it is one person's look, not the word's
    # picture, so a board without that look still needs its own.
    def art_present?(image, owner_id)
      image.docs.any? { |doc| !doc.likeness? && [User::DEFAULT_ADMIN_ID, owner_id].include?(doc.user_id) }
    end

    # The picture already drawn for this owner and this look, if there is one —
    # a communicator's second board, or a sibling who looks the same, costs
    # nothing. Only ever asked where generation would otherwise run, so it never
    # replaces art a tile would have shown anyway.
    def reusable_url(image:, owner_id:, likeness:)
      return nil unless likeness

      image.likeness_doc_for(user_id: owner_id, fingerprint: likeness.fingerprint)&.tile_url.presence
    end

    # Points the board's tile at a reusable picture. Returns whether it did, so
    # the caller can skip enqueuing. Never un-hides a tile (see
    # BoardImage#picture_hidden?).
    def reuse!(image:, board:, likeness:)
      url = reusable_url(image: image, owner_id: board.user_id, likeness: likeness)
      return false unless url

      tile = board.board_images.find_by(image_id: image.id)
      return false unless tile
      return true if tile.picture_hidden?

      tile.update_column(:display_image_url, url)
      true
    end
  end
end
