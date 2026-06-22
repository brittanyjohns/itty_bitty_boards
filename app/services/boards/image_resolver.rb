# app/services/boards/image_resolver.rb
#
# Resolves a tile label to the best Image to display, PREFERRING the curated
# "default" image — the admin/public image for that label with the MOST docs
# (artwork) attached.
#
# The Board Builder seeds and clones a lot of folder tiles (Animals, People,
# Feelings, Food, …) whose labels match curated library art. But several Image
# rows can share a label, and a naive `find_by(label:)` returns the lowest-id
# match — often a blank, art-less Image the OBF seed created — so the folder
# tile renders empty even though a curated image with art exists. `Image#display_doc`
# has no label fallback, so once a tile points at a blank image it stays blank.
#
# When more than one art-bearing image exists for a label, we pick the one with
# the most docs: that's the established/canonical symbol the library has built
# up the most artwork for, and the one an admin would consider the default.
module Boards
  module ImageResolver
    module_function

    # Returns a persisted Image for `label`. `owner` is the User who owns any
    # newly-created image and whose private images are preferred.
    #
    # Matching is case-INSENSITIVE: folder labels are capitalized ("Animals",
    # "People") while curated library art is often stored lowercase, and a
    # case-sensitive `find_by(label:)` would miss it and fall through to a blank.
    # A newly-created image keeps the normalized label's original casing.
    def resolve(label, owner:)
      word = Boards::InterestWords.normalize_word(label)

      # 1/2. The owner's own art image, else the curated public/admin "default"
      #      image for this label (the one with the most docs attached).
      arted = best_arted_for(word, owner)
      return arted if arted

      # 3. No art anywhere — keep an existing (blank) image, else create one.
      owner.images.where(ci_label, word).first ||
        default_public_scope.where(ci_label, word).first ||
        Image.create!(label: word, user_id: owner.id)
    end

    # Re-points every blank (art-less) tile on `board` to the curated art-bearing
    # image for the same label, leaving tiles that already have art untouched.
    # This is the same blank->art upgrade `SeededSetCloner#copy_tiles!` does for
    # the root board, extracted so the fringe/cloned boards (which clone through
    # `Board#clone_with_images`, with no upgrade) render with pictures too.
    #
    # Only ever upgrades blank -> art, never the reverse. The authored tile text
    # is preserved: a curated art image may be stored under different casing
    # ("animals"), and we must not rename folder tiles ("Animals").
    def upgrade_board_tiles!(board, owner:)
      board.board_images.includes(:image).find_each do |bi|
        image = bi.image
        next if art?(image)

        label = bi.label.presence || image&.label
        next if label.blank?

        # best_arted (not resolve) so we never create a stray blank image: we
        # only re-point when curated art actually exists for the label.
        arted = best_arted_for(label, owner)
        next if arted.nil?
        next if arted.id == image&.id

        bi.image_id = arted.id
        bi.display_image_url = arted.display_image_url(owner).presence || arted.src_url
        # Pin the authored tile text — resolve() may return a different-cased
        # label and saving must not rename the tile.
        bi.display_label = bi.display_label.presence || label
        bi.label = label
        bi.save!
      end
    end

    # True when the image has displayable artwork (at least one Doc). Cheap SQL,
    # no S3 — mirrors the `image.docs.any?` notion used elsewhere in the builder.
    def art?(image)
      image.present? && image.docs.exists?
    end

    # The best art-bearing image for `label`: the owner's own art first, then
    # the curated public/admin "default" (most docs). Read-only — never creates.
    # `label` may be in any casing; it is normalized here.
    def best_arted_for(label, owner)
      word = Boards::InterestWords.normalize_word(label)
      best_arted(owner.images, word) || best_arted(default_public_scope, word)
    end

    # The art-bearing image for `word` in `relation` with the MOST docs (the
    # "default"/canonical symbol), tie-broken by lowest id for determinism.
    # Returns nil when no image for the label has art.
    def best_arted(relation, word)
      relation
        .where(ci_label, word)
        .left_joins(:docs)
        .group("images.id")
        .having("COUNT(docs.id) > 0")
        .order(Arel.sql("COUNT(docs.id) DESC, images.id ASC"))
        .first
    end

    # Curated, non-private images owned by the default admin (or unowned).
    def default_public_scope
      Image.public_img.where(user_id: [User::DEFAULT_ADMIN_ID, nil])
    end

    # Case-insensitive label match fragment for `where`.
    def ci_label
      "LOWER(label) = LOWER(?)"
    end
  end
end
