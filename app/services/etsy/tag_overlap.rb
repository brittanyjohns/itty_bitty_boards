# frozen_string_literal: true

# How much a printable's tag set overlaps other printables' — the check that
# would have caught nine listings shipping to Etsy in Aug 2026 with identical
# 13-tag sets. Etsy caps how many results from one shop appear per query, so
# heavily-overlapping listings compete with each other instead of reaching new
# buyers.
#
# WARNS, never blocks. Some overlap is correct: three core-vocabulary products
# at different sizes genuinely share most of their tags because they are the
# same product. Only an admin can tell that apart from a mistake, so this
# surfaces the collision and names the shared tags rather than refusing a save.
#
# Read-only and side-effect free — safe to call from a view.
module Etsy
  class TagOverlap
    # 10 of Etsy's 13. Below this, two AAC printables sharing the always-on and
    # audience boilerplate is expected and not worth a warning.
    HIGH_OVERLAP = 10

    # How many tags a printable's TOPIC has to yield to stay under the warning.
    #
    # Every other pool is shared boilerplate by design, so two listings differing
    # only in topic share `TAG_MAX - t` tags, where t is the number of topic tags
    # each one has (the shortfall is made up from the same ordered `top_up` list,
    # which is why a short topic collides twice over). Setting `13 - t <
    # HIGH_OVERLAP` gives the minimum below.
    #
    # It is derived rather than written as a number so that moving either
    # constant can't leave the admin hint quoting a stale one — the number an
    # admin is told is the number the check actually uses.
    MIN_TOPIC_TAGS = CopyRules::TAG_MAX - HIGH_OVERLAP + 1

    # Only printables that already have saved listing copy are compared, and
    # only the most recent slice of them: generating defaults for every row to
    # compare against would make this page's cost grow with the table.
    SCAN_LIMIT = 200

    # Enough to show the pattern ("it collides with these three") without
    # turning the warning into a wall the admin scrolls past.
    MAX_MATCHES = 3

    Match = Struct.new(:printable, :shared, keyword_init: true) do
      def count = shared.size
    end

    def initialize(printable, tags: nil)
      @printable = printable
      @tags = normalize(tags || printable.listing_copy_or_default["tags"])
    end

    def any? = matches.any?

    # Highest overlap first, so the worst collision is the one an admin reads.
    def matches
      @matches ||= begin
        if @tags.empty?
          []
        else
          candidates.filter_map { |other|
            shared = @tags & normalize(other.listing_copy["tags"])
            Match.new(printable: other, shared: shared) if shared.size >= HIGH_OVERLAP
          }.sort_by { |match| -match.count }.first(MAX_MATCHES)
        end
      end
    end

    private

    def candidates
      scope = BoardPrintable.includes(:board).order(created_at: :desc)
      scope = scope.where.not(id: @printable.id) if @printable.id
      scope.limit(SCAN_LIMIT).select { |other| other.listing_copy.present? }
    end

    def normalize(tags) = Array(tags).map { |tag| tag.to_s.strip.downcase }.reject(&:empty?).uniq
  end
end
