# frozen_string_literal: true

# Every number and product claim a STYLED gallery slide makes, in one place.
#
# The slides are marketing art, but the claims on them are promises to a buyer:
# "309 symbol-supported words", "Color + low-ink versions", "3 PDFs". A number
# typed into a template (or into an image-model prompt, which is where the
# design these slides copy came from) is true for exactly one product. So a
# slide reads its facts from here and nowhere else, and every fact is derived
# from the boards and the files that actually ship.
#
# `listing` narrows the file facts to what that listing sells — a listing can
# drop the low-ink PDF (`pdf_variants`), and then "Color + low-ink" is false for
# it even though the printable has the file.
#
# Deliberately never claims PNG: the downloads are PDFs only
# (BoardPrintable::KIND_DOWNLOADABLE).
module Printables
  class GalleryFacts
    LETTER_SIZE_LABEL = "8.5 x 11 in"

    attr_reader :printable, :listing

    def initialize(printable, listing: nil)
      @printable = printable
      @listing = listing
    end

    def board_count = [board_ids.size, 1].max

    def set? = board_count > 1

    def letter_size_label = LETTER_SIZE_LABEL

    # DISTINCT symbol-supported words across the whole set. Distinct, because a
    # built set reproduces its nav strip on every page and counting totals would
    # sell "this" and "that" once per page.
    def word_count
      @word_count ||= BoardImage
        .where(board_id: board_ids, hidden: false)
        .includes(:image, :predictive_board)
        .filter_map { |tile| word_for(tile) }
        .uniq
        .size
    end

    # The single-board document carries every variant's pages, so it counts.
    # A blob with no variant predates the metadata and is that same document.
    def low_ink?
      variants = pdf_variants
      variants.include?(BoardPrintable::VARIANT_LOW_INK) || variants.include?(BoardPrintable::VARIANT_FULL)
    end

    # Same rule as low_ink?: the single-board document carries the trim-ready
    # pages too.
    def trim_ready?
      variants = pdf_variants
      variants.include?(BoardPrintable::VARIANT_TRIM_READY) || variants.include?(BoardPrintable::VARIANT_FULL)
    end

    def pdf_count = pdf_files.size

    def formats_label = pdf_count > 1 ? "#{pdf_count} PDFs" : "PDF"

    def board_names
      @board_names ||= printable.ordered_boards.map { |b| Boards::AssetRendering.board_title_for(b) }
    end

    # The address the root page's printed QR opens: the BARE /pb/<slug>, never
    # a UTM-tagged one, because it is the same URL the paper carries.
    def online_url = Boards::Printables::Qr.target_url_for(printable.board)

    # What a browser bar shows: no scheme.
    def online_display_url = online_url.delete_prefix("https://").delete_prefix("http://")

    # Whether a BUYER can open the online version with no account. /pb/<slug>
    # resolves anonymously only for a published board (Board#viewable_by?), and
    # every page carries its own QR, so the claim needs every board in the set.
    # Nothing in the printable pipeline publishes a board, so this is a real
    # question, not a formality: "Free" and "No sign-in required" are only
    # printed when it is true.
    def online_public?
      return @online_public if defined?(@online_public)

      @online_public = board_ids.any? && !Board.where(id: board_ids).where(published: [false, nil]).exists?
    end

    def to_h
      {
        board_count: board_count,
        word_count: word_count,
        low_ink: low_ink?,
        trim_ready: trim_ready?,
        formats_label: formats_label,
        board_names: board_names,
        online_url: online_url,
        online_public: online_public?,
      }
    end

    # What a styled slide is stamped with. A slide whose digest no longer
    # matches is quoting a fact that has since changed.
    def digest = Digest::SHA256.hexdigest(to_h.to_json)[0, 16]

    private

    def board_ids = (printable.board_ids.to_a.presence || [printable.board_id]).compact

    def pdf_files = (listing || printable).pdf_files

    def pdf_variants
      pdf_files.map { |f| f.metadata["variant"].presence || BoardPrintable::VARIANT_FULL }
    end

    # A word is a tile a communicator speaks, shown with a picture.
    #
    # Folder and way-back tiles are navigation, and keyboard keys are letters.
    # The picture resolves with a BARE `||`: a blank display_image_url is the
    # "this tile has no picture" marker, and `""` stops the chain exactly as it
    # does on screen and in print (Boards::BoardPdfLayoutNormalizer), so a
    # colour-swatch tile never counts as symbol-supported. The Image's src_url
    # stands in for its resolved doc — the cheap column, not a query per tile.
    def word_for(tile)
      return nil if tile.door_tile? || tile.back_tile? || tile.keyboard_key?

      picture = tile.display_image_url || tile.image&.src_url
      return nil if picture.blank?

      (tile.display_label || tile.label).to_s.squish.downcase.presence
    end
  end
end
