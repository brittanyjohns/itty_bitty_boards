module Boards
  # A multi-word tile that misses the symbol library falls back to its HEAD
  # WORD's picture before it falls back to a text placeholder.
  #
  # `Image.by_label` matches a whole label exactly (`LOWER(images.label) = ?`),
  # so a phrase either has a library row of its own or it has nothing — there
  # is no decomposition anywhere in the resolver chain. On a generated
  # circle-time board that meant `I feel happy` and `I feel sad` resolved to
  # real art while `I feel tired`, built identically, rendered as an inline
  # `data:image/svg+xml` of its own text. On screen that is a visibly emptier
  # tile; on the laminated print such a board is destined for, it is a blank
  # square.
  #
  # Two deliberate limits:
  #
  # - The fallback is written to the TILE (`board_images.display_image_url`),
  #   never to the shared `Image`. `images` rows are library rows — one "i feel
  #   tired" is on boards across unrelated accounts — and giving that row
  #   "tired"'s art would hand it to all of them and stop art generation ever
  #   running for the phrase. Per-tile keeps it to the board that needed it,
  #   which is the same rule Images::TileArtFanout enforces from the other side.
  # - It answers nil rather than guessing. "how are you" is all function words,
  #   so it has no head word and keeps the placeholder; a bad picture on an AAC
  #   tile is worse than none, because the picture is what a nonspeaking user
  #   reads.
  class PhraseArtFallback
    # Words that never carry a phrase's meaning, so never its picture. Content
    # verbs are deliberately absent: "I feel tired" and "I want juice" both
    # resolve correctly from the last token without dropping "feel" or "want",
    # and dropping them would strip the head off "I feel" itself.
    FUNCTION_WORDS = %w[
      a an the this that these those
      my your our their his her its
      i you he she it we they me him us them
      is am are was were be been being
      do does did doing
      can could will would shall should may might must
      to of for with at on in from by about
      please and or but not
      how what where when why who
    ].freeze

    # The token a phrase's picture should come from: the LAST word that carries
    # meaning. English head-final noun and adjective phrases put it there —
    # "I feel tired" → "tired", "my turn" → "turn", "song please" → "song".
    def self.head_word(label)
      tokens = label.to_s.unicode_normalize(:nfkc).tr("‘’", "''").downcase
                    .gsub(/[^\p{Alnum}'\s-]/, " ").split
      return nil if tokens.size < 2

      tokens.reverse.find { |token| !FUNCTION_WORDS.include?(token) }
    end

    # The head word's tile art, or nil. Looks up EXISTING library rows only —
    # never creates one, so a miss costs a query and changes nothing.
    def self.art_for(label, user: nil)
      head = head_word(label)
      return nil if head.blank?

      image = (user&.images&.by_label(head)&.first if user) ||
              Image.public_img.by_label(head).find_by(user_id: [User::DEFAULT_ADMIN_ID, nil])
      return nil if image.nil?

      image.display_tile_url(user).presence
    end
  end
end
