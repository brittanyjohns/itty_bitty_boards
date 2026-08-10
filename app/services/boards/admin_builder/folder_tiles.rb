module Boards
  module AdminBuilder
    # Guarantees every child page is reachable: a page with nothing pointing at
    # it gets a folder tile on the main board, written into the root word list.
    #
    # **A page nobody can open is never what was meant.** `links_to` is a
    # hand-typed `>key` token in the textarea, and only SetDrafter ever emits
    # one — PageDrafter knows about a single page and can't name a sibling, and
    # WordListDrafter has no concept of links and *replaces* the root list, so
    # re-drafting the main board after drafting a set silently deleted every
    # folder tile it had. The build then published the pages anyway
    # (`Board#viewable_by?` gates each board on its own flag, so they are live
    # but unreachable) because PlanValidator only ever checked the forward
    # direction — a link naming a page that doesn't exist — never that a page
    # is named by anything.
    #
    # Reachability is not an authoring preference, so this runs on every form
    # round-trip rather than behind a button. What it did is reported back, not
    # applied silently: `Result#changed?` drives the banner on the form and the
    # preview.
    #
    # Only the ROOT gains tiles, but a page counts as reachable when ANY page
    # links to it — a page opened from a sibling is already reachable, and
    # adding a second door to it from the main board isn't this module's call.
    module FolderTiles
      # A folder tile is a category tile, and a category tile's label is
      # authored: "Food" opens a page, "food" says the word. `Image#set_label`
      # folds a plain leading capital, so the authored casing is pinned as the
      # tile's own display_label rather than left to the shared Image.
      FOLDER_PART_OF_SPEECH = "noun".freeze

      Result = Struct.new(:tiles, :added, :displaced, keyword_init: true) do
        def changed? = added.any?
      end

      module_function

      # `root_tiles` and each child's `tiles` are Plan tile hashes; `tile_count`
      # is the root's authored size (0 when unset — then nothing is displaced).
      def link(root_tiles:, children:, tile_count: 0)
        tiles = Array(root_tiles).map(&:dup)
        pending = unlinked_pages(tiles, children)
        return Result.new(tiles: tiles, added: [], displaced: []) if pending.empty?

        known = known_keys(children)
        added = []
        appended = []

        pending.each do |page|
          key = page[:key].to_s.strip.downcase

          # A tile already carrying the page's word is promoted rather than
          # duplicated — appending a second "Food" would trip the duplicate-word
          # check and cost a cell for nothing.
          if (existing = promotable_tile(tiles, page, appended, known))
            existing[:links_to] = key
            existing[:part_of_speech] = FOLDER_PART_OF_SPEECH if existing[:part_of_speech].to_s == "default"
            existing[:display_label] ||= page_label(page)
            added << { key: key, label: existing[:label].to_s }
          else
            appended << folder_tile(page)
            added << { key: key, label: page_label(page) }
          end
        end

        tiles, displaced = fit(tiles, appended, tile_count)
        Result.new(tiles: tiles, added: added, displaced: displaced)
      end

      # How many cells the root has to leave for folder tiles when its word
      # list is about to be drafted from scratch. Drafting replaces the root
      # outright, so every keyed page will need a door — asking the drafter for
      # that many fewer words lands on the tile count exactly, instead of
      # drafting a full board and then displacing the tail of it.
      def reserved_count(children:)
        Array(children).count { |child| linkable_key?(child[:key]) }
      end

      # Pages that nothing — root or sibling — currently opens.
      def unlinked_pages(root_tiles, children)
        linked = link_targets(root_tiles, children)

        Array(children).select do |child|
          linkable_key?(child[:key]) && linked.exclude?(child[:key].to_s.strip.downcase)
        end
      end

      def link_targets(root_tiles, children)
        pages = [Array(root_tiles)] + Array(children).map { |child| Array(child[:tiles]) }
        pages.flatten.filter_map { |tile| tile[:links_to].presence }.to_set
      end

      # A key that fails this is a key PlanValidator is about to reject on its
      # own terms, and emitting a link to it would stack a second, more
      # confusing error on top of the real one.
      def linkable_key?(key)
        key = key.to_s.strip.downcase
        key.present? && key != Plan::ROOT_KEY && key.match?(/\A[a-z0-9_]+\z/)
      end

      def page_label(page)
        page[:name].to_s.strip.presence || page[:key].to_s.tr("_", " ").strip
      end

      def folder_tile(page)
        label = page_label(page)
        {
          label: label,
          part_of_speech: FOLDER_PART_OF_SPEECH,
          display_label: label,
          links_to: page[:key].to_s.strip.downcase,
        }
      end

      def known_keys(children)
        Array(children).filter_map { |child| child[:key].to_s.strip.downcase.presence }.to_set << Plan::ROOT_KEY
      end

      # Matches on the page's name or its key read as words, and takes over a
      # tile that links nowhere OR whose target doesn't exist — a mistyped
      # `>fod` is a door meant for this page, and retargeting it is better than
      # leaving a dangling link next to a freshly appended duplicate of the same
      # word.
      def promotable_tile(tiles, page, appended, known)
        wanted = [page_label(page), page[:key].to_s.tr("_", " ")].map { |value| value.strip.downcase }
        taken = appended.map { |tile| tile[:label].to_s.downcase }

        tiles.find do |tile|
          target = tile[:links_to].presence
          next false if target && known.include?(target)
          next false unless wanted.include?(tile[:label].to_s.strip.downcase)

          taken.exclude?(tile[:label].to_s.downcase)
        end
      end

      # Folder tiles are appended, and the root is normally authored to exactly
      # its tile count — so making room is part of adding one. Trailing plain
      # words go first and are named in the report: a word is regenerable and a
      # door is not, and a board that overflows its grid can't be built at all.
      # Never drops another folder tile, and never trims below the appended
      # tiles themselves.
      def fit(tiles, appended, tile_count)
        overflow = tile_count.to_i.positive? ? (tiles.size + appended.size) - tile_count.to_i : 0
        return [tiles + appended, []] unless overflow.positive?

        displaced = []
        kept = tiles.reverse.reject do |tile|
          next false unless displaced.size < overflow
          next false if tile[:links_to].present?

          displaced << tile[:label].to_s
          true
        end.reverse

        [kept + appended, displaced.reverse]
      end
    end
  end
end
