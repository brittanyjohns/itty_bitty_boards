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

    # Top-level admin boards a human would recognize.
    #
    # Deliberately NOT Board.main_boards here. main_boards composes
    # non_menus, which is `where.not(board_type: "menu").where.not(parent_type:
    # "Menu")`. In SQL, `NULL != 'menu'` evaluates to NULL (not TRUE), so
    # where.not(board_type: "menu") silently excludes every board with a
    # NULL board_type — even though NULL isn't "menu" and those boards
    # should be searchable. Verified against production data: 11 admin-owned,
    # top-level, published/tagged boards have board_type: nil and were
    # invisible to this endpoint before this fix.
    #
    # Reimplement the same "not a menu, not a sub-board" filter here using
    # IS DISTINCT FROM, which treats NULL as simply "not equal to 'menu'"
    # (the behavior a human reading `.where.not` would expect). Do NOT swap
    # this back for `Board.main_boards`/`Board.non_menus` — those scopes are
    # used elsewhere in the app and changing their NULL semantics there
    # could have effects far outside this feature. This fix is intentionally
    # local to AdminSearch. (parent_type is NOT NULL in the schema, so
    # where.not(parent_type: "Menu") is safe as-is.)
    def self.base_scope
      Board.where(user_id: User::DEFAULT_ADMIN_ID)
           .where("boards.board_type IS DISTINCT FROM 'menu'")
           .where.not(parent_type: "Menu")
           .where(sub_board: [false, nil])
           .not_builder_child
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
    # Chain both onto base_scope (not a bare Board.*) before plucking — a
    # common term unscoped can pluck thousands of ids across the whole
    # boards table, almost all of them user-owned boards the outer scope
    # would then discard. pg_search scopes compose onto a relation cleanly
    # (verified), so this only changes how many ids get plucked, not what
    # the final result set contains — it's already ANDed with `scope`.
    def apply_query(scope)
      return scope if q.blank?

      name_ids = self.class.base_scope.search_by_name(q).pluck(:id)
      desc_ids = self.class.base_scope.where("boards.description ILIKE ?", "%#{sanitize_like(q)}%").pluck(:id)

      scope.where(id: (name_ids + desc_ids).uniq)
    end

    def sanitize_like(value)
      ActiveRecord::Base.sanitize_sql_like(value)
    end

    # Consistent with Images::LabelSearch#clamp: a blank value (omitted
    # keyword arg, nil, or an empty string) means "use the default"; an
    # explicit out-of-range number clamps into range instead.
    def clamp(value)
      return DEFAULT_LIMIT if value.blank?

      value.to_i.clamp(1, MAX_LIMIT)
    end
  end
end
