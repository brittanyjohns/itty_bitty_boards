# Port of the printables pipeline's step 05 (build-content). Walks the board
# tree, then renders every board twice — once in colour, once low-ink.
#
# The renderer itself already exists: this goes straight to
# Boards::RenderAssetData rather than HTTP-calling our own
# /api/internal/boards/:id/export.pdf endpoint the way the Node pipeline does.
module Boards
  module Printables
    class CollectPages
      # Raised when the walked tree would exceed max_boards. The pipeline
      # throws rather than truncating, and so do we — silently dropping boards
      # would ship an incomplete product that looks complete.
      class TreeTooLargeError < StandardError; end

      # `/pb/:key` resolves either form — BoardsController#set_board tries
      # `find_by(id:)` then `find_by(slug:)` — and Board#public_url already
      # uses the slug, so the QR matches the link we hand out everywhere else.
      #
      # This is safe to print because a PUBLISHED board's slug is frozen
      # (Board#slug_locked?, #611) — and only a published board is shareable
      # in the first place. The column still defaults to "", hence `qr_key_for`
      # falling back to the id, which never changes.
      QR_BASE_URL = "https://app.speakanyway.com/pb".freeze

      Page = Struct.new(:pdf_bytes, :board_id, :board_name, :variant, keyword_init: true)

      # Breadth-first from the root, root first, deduped by board id.
      #
      # Exposed as a class method because the controller needs the tree size
      # *synchronously*, before it creates a record or enqueues anything — a
      # job that raises can't produce a 422.
      def self.walk_board_tree(board:, include_subboards: false, max_boards: BoardPrintable::DEFAULT_MAX_BOARDS)
        return [board] unless include_subboards

        # Seeding visited with the root is what stops a child that links back
        # to the root from looping forever.
        visited = Set.new([board.id])
        ordered = [board]
        queue = [board]

        until queue.empty?
          current = queue.shift

          child_ids = BoardImage
            .where(board_id: current.id)
            .where.not(predictive_board_id: nil)
            .order(:position, :id)
            .pluck(:predictive_board_id)

          child_ids.each do |child_id|
            next if child_id == current.id || visited.include?(child_id)

            child = Board.find_by(id: child_id)
            next unless child

            visited << child_id
            if visited.size > max_boards
              raise TreeTooLargeError,
                "This board links to more than #{max_boards} boards. " \
                "Raise the board limit or turn off subboards."
            end

            ordered << child
            queue << child
          end
        end

        ordered
      end

      def initialize(board:, include_subboards: false, max_boards: BoardPrintable::DEFAULT_MAX_BOARDS)
        @board = board
        @include_subboards = include_subboards
        @max_boards = max_boards
      end

      # => { boards: [Board], pages: [Page] }
      #
      # Page order matches the pipeline: every colour page in BFS order, then
      # every low-ink page in the same board order.
      def call
        boards = self.class.walk_board_tree(
          board: board,
          include_subboards: include_subboards,
          max_boards: max_boards,
        )

        color_pages = boards.map { |b| render_page(b, variant: BoardPrintable::VARIANT_COLOR) }
        low_ink_pages = boards.map { |b| render_page(b, variant: BoardPrintable::VARIANT_LOW_INK) }

        { boards: boards, pages: color_pages + low_ink_pages }
      end

      private

      attr_reader :board, :include_subboards, :max_boards

      def render_page(target, variant:)
        hide_colors = variant == BoardPrintable::VARIANT_LOW_INK

        # hide_header stays false on every board page: the QR lives inside the
        # header in print.html.erb, so hiding the header would also kill the
        # per-page QR. There is no header-less-with-QR combination.
        render_data = Boards::RenderAssetData.new(
          board: target,
          screen_size: "lg",
          hide_colors: hide_colors,
          hide_header: false,
          routes: Rails.application.routes.url_helpers,
          include_qr: true,
          qr_target_url: qr_target_url_for(target),
        ).call

        html = ApplicationController.render(
          template: "api/boards/print",
          layout: "pdf",
          assigns: render_data,
          formats: [:html],
        )

        Page.new(
          pdf_bytes: Grover.new(html, **grover_options(render_data[:landscape])).to_pdf,
          board_id: target.id,
          board_name: target.name,
          variant: variant,
        )
      end

      # Every board page's QR targets ITS OWN board, so a buyer scanning page 5
      # of a 9-board bundle lands on that board rather than the root. Only the
      # cover's QR points at the root (see RenderWrappers).
      def qr_target_url_for(target) = "#{QR_BASE_URL}/#{self.class.qr_key_for(target)}"

      # Slug when there is one, id otherwise. Class-level because RenderWrappers
      # builds the cover's QR the same way and the two must never disagree.
      def self.qr_key_for(board) = board.slug.presence || board.id

      # Board pages keep the automatic orientation from
      # RenderAssetData#resolved_landscape (anything with ≥6 tiles goes
      # landscape). The merge preserves each page's own size, so a finished
      # printable legitimately mixes portrait wrappers with landscape boards.
      def grover_options(landscape)
        {
          format: "Letter",
          landscape: landscape,
          viewport: { width: landscape ? 792 : 612, height: landscape ? 612 : 792 },
          full_page: false,
          prefer_css_page_size: true,
          print_background: true,
        }
      end
    end
  end
end
