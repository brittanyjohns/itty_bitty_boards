# app/services/boards/image_resolver.rb
#
# Resolves a tile label to the best Image to display, PREFERRING one that
# actually has artwork.
#
# The Board Builder seeds and clones a lot of folder tiles (Animals, People,
# Feelings, Food, …) whose labels match curated library art. But a naive
# `find_by(label:)` returns the lowest-id match, which is often a blank,
# art-less Image the OBF seed created for that same label — so the folder tile
# renders empty even though a curated image with art exists. `Image#display_doc`
# has no label fallback, so once a tile points at a blank image it stays blank.
#
# This picks an art-bearing image when one exists for the label, only
# falling back to (or creating) a blank image as a last resort.
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

      # 1. The owner's own image for this label, if it already has art.
      owner_arted = owner.images.with_docs.where(ci_label, word).first
      return owner_arted if owner_arted

      # 2. A curated public/admin image for this label that has art.
      public_arted = Image.public_img.with_docs
        .where(user_id: [User::DEFAULT_ADMIN_ID, nil]).where(ci_label, word).first
      return public_arted if public_arted

      # 3. No art anywhere — keep an existing (blank) image, else create one.
      owner.images.where(ci_label, word).first ||
        Image.public_img.where(user_id: [User::DEFAULT_ADMIN_ID, nil]).where(ci_label, word).first ||
        Image.create!(label: word, user_id: owner.id)
    end

    # True when the image has displayable artwork (at least one Doc). Cheap SQL,
    # no S3 — mirrors the `image.docs.any?` notion used elsewhere in the builder.
    def art?(image)
      image.present? && image.docs.exists?
    end

    # Case-insensitive label match fragment for `where`.
    def ci_label
      "LOWER(label) = LOWER(?)"
    end
  end
end
