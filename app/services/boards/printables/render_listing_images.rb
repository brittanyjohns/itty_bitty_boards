# Renders the marketplace gallery images for a printable: the cover, and a
# "what's included" slide.
#
# Etsy will create a listing with no photos but will not let it go live without
# one, so these are the minimum a draft needs to be finishable. The richer
# gallery — lifestyle mockups, scene shots, the about slide — is still the
# speakanyway-printables pipeline's job (its steps 13/14); reproducing that here
# would mean compositing over photography, which is a different project.
#
# Both images come from the SAME templates and CSS as the printed wrapper pages,
# rendered through layouts/pdf_printable with `@listing_image` set. A buyer
# should not be able to tell the gallery and the product apart.
#
# Grover work, so it belongs on Sidekiq, never a request thread.
module Boards
  module Printables
    class RenderListingImages
      # Etsy's recommended shortest edge is 2000px. The sheet is 8.5in wide at
      # 96 CSS px/in = 816px, so a device_scale_factor of 2.5 lands at 2040 —
      # over the recommendation without paying for a 3x render.
      CANVAS_PX = 816
      SCALE = 2.5

      def initialize(printable:)
        @printable = printable
      end

      # => [BoardPrintable::IMAGE_COVER, BoardPrintable::IMAGE_WHATS_INCLUDED]
      def call
        printable.attach_image!(bytes: cover_png, variant: BoardPrintable::IMAGE_COVER)
        printable.attach_image!(bytes: whats_included_png, variant: BoardPrintable::IMAGE_WHATS_INCLUDED)
        BoardPrintable::LISTING_IMAGE_ORDER
      end

      private

      attr_reader :printable

      def board = printable.board

      def board_count = [printable.board_ids.to_a.size, 1].max

      def set? = board_count > 1

      # The same assigns RenderWrappers builds for the printed cover, so the
      # gallery's first image is literally the product's first page. Kept in
      # sync by construction: the wrapper service owns the values, this just
      # asks it for them.
      def cover_png
        wrappers = RenderWrappers.new(board: board, board_count: board_count, topic: printable.topic)
        render_png("cover", assigns: wrappers.cover_assigns)
      end

      def whats_included_png
        render_png("whats_included", assigns: whats_included_assigns)
      end

      def whats_included_assigns
        {
          heading: Boards::AssetRendering.board_title_for(board),
          subtitle: subtitle,
          items: included_items,
          board_labels: board_labels,
        }
      end

      def subtitle
        return "Words for #{printable.topic}" if printable.topic.present?
        return "A set of #{board_count} printable communication boards" if set?

        "A printable communication board"
      end

      # Shared with the listing description so the slide and the text make the
      # same promises in the same words.
      #
      # Root-scoped: this class is itself inside `Boards::Printables`, so a bare
      # `Printables::` resolves to that and never reaches the top-level module.
      def included_items
        ::Printables::IncludedItems.all(board_count: board_count, page_count: printable.page_count)
      end

      # board_ids is in tree order (root first) and a `where` loses it, so the
      # names are put back into it. Capped because the callout is one line of a
      # fixed-height slide — a 25-board set would overflow the sheet.
      MAX_LABELS = 12

      def board_labels
        ids = printable.board_ids.to_a
        return [] if ids.size <= 1

        names = Board.where(id: ids).pluck(:id, :name).to_h
        labels = ids.filter_map { |id| names[id].presence }
                    .map { |n| Etsy::CopyRules.title_case_words(n) }
                    .uniq
        return labels if labels.size <= MAX_LABELS

        labels.first(MAX_LABELS) + ["and #{labels.size - MAX_LABELS} more"]
      end

      def render_png(template, assigns:)
        html = ApplicationController.render(
          template: "api/board_printables/#{template}",
          layout: "pdf_printable",
          assigns: assigns.merge(listing_image: true),
          formats: [:html],
        )

        Grover.new(
          html,
          format: "png",
          viewport: { width: CANVAS_PX, height: CANVAS_PX },
          width: CANVAS_PX,
          height: CANVAS_PX,
          device_scale_factor: SCALE,
          print_background: true,
        ).to_png
      end
    end
  end
end
