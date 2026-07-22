# app/services/boards/admin_search.rb
#
# Search over admin-owned boards for the internal API — published AND
# unpublished, filterable by tag, name and description.
#
# Two deliberate choices:
#
#   * `q` matches name via pg_search (prefix) OR description via ILIKE
#     (substring). Those aren't comparably ranked, so results order by
#     updated_at desc rather than faking a combined relevance score.
#   * `description` is NOT added to Board.search_by_name — that scope is used
#     elsewhere and widening it would silently change existing results.
module Boards
  class AdminSearch
    MAX_LIMIT = 100
    DEFAULT_LIMIT = 25

    attr_reader :q, :tags, :tag_match, :published, :limit, :page

    def initialize(q: nil, tags: nil, tag_match: "all", published: nil, limit: DEFAULT_LIMIT, page: 1)
      @q = q.to_s.strip
      @tags = tags
      @tag_match = tag_match.to_s == "any" ? "any" : "all"
      @published = published
      @limit = clamp(limit)
      @page = [page.to_i, 1].max
    end

    def call
      scope = self.class.base_scope
      scope = apply_published(scope)
      scope = apply_tags(scope)
      scope = apply_query(scope)
      scope.with_artifacts.order(updated_at: :desc).page(page).per(limit)
    end

    # Top-level admin boards a human would recognize. main_boards already
    # covers non_menus + not a sub_board.
    def self.base_scope
      Board.where(user_id: User::DEFAULT_ADMIN_ID).main_boards.not_builder_child
    end

    def self.tag_counts(published: nil)
      scope = base_scope
      scope = scope.where(published: published) unless published.nil?

      scope
        .select(Arel.sql("unnest(tags) AS tag"))
        .then { |inner| Board.from(inner, :tags_expanded) }
        .group("tag")
        .order(Arel.sql("COUNT(*) DESC, tag ASC"))
        .count
        .map { |tag, count| { tag: tag, count: count } }
    end

    private

    def apply_published(scope)
      return scope if published.nil?

      scope.where(published: published)
    end

    def apply_tags(scope)
      return scope if tags.blank?

      tag_match == "any" ? scope.with_any_tags(tags) : scope.with_all_tags(tags)
    end

    # pg_search relations don't compose with .or, so resolve each side to ids.
    def apply_query(scope)
      return scope if q.blank?

      name_ids = Board.search_by_name(q).pluck(:id)
      desc_ids = Board.where("boards.description ILIKE ?", "%#{sanitize_like(q)}%").pluck(:id)

      scope.where(id: (name_ids + desc_ids).uniq)
    end

    def sanitize_like(value)
      ActiveRecord::Base.sanitize_sql_like(value)
    end

    def clamp(value)
      value = value.to_i
      return DEFAULT_LIMIT if value.zero?

      value.clamp(1, MAX_LIMIT)
    end
  end
end
