# app/services/boards/robust_sets.rb
#
# Lookup helpers for the Board Builder's "robust vocabulary set" templates
# (Core 60, Core 84). These sets are seeded (see lib/tasks/vocab_sets.rake) as
# admin-owned, predefined linked board trees and identified ENTIRELY by a marker
# on their ROOT board's settings JSONB — there is no BoardGroup. This module is
# the single place that query lives, shared by the wizard catalog, the create
# endpoint, and the seeder.
#
#   settings["board_builder_robust"]      => true   (root marker)
#   settings["board_builder_robust_slug"] => "core-60"
module Boards
  module RobustSets
    ROOT_MARKER = "board_builder_robust"
    SLUG_MARKER = "board_builder_robust_slug"

    # The name a BUILT set takes for each slug. Deliberately NOT the seed row's
    # `name` column: the seed is a mutable admin board, and reading its name is
    # what let a stray marketing clone ("Classroom — Core Words Poster") rename
    # every user's Extended build. A set's display name is a property of the
    # SLUG, which nothing but a re-seed can change.
    SET_NAMES = {
      "core-60" => "Core 60",
      "core-84" => "Core 84",
    }.freeze

    module_function

    # All seeded robust-set ROOT boards (one per set), stable order for the
    # catalog. Empty when nothing is seeded in this environment — callers degrade
    # gracefully (the set just doesn't appear in the picker).
    #
    # Scoped to the SEEDER's own boards, because the marker rides `settings` and
    # `Board#clone_with_images` used to dup it verbatim — so any clone of a seed
    # became a rival root for that slug. Two independent rails: the seeder owns
    # its boards as `User::DEFAULT_ADMIN_ID` (VocabSets.admin), and a clone is
    # always `predefined: false`. Ordered by :id, not :name, so the winner is the
    # oldest row rather than whatever happens to sort first alphabetically.
    def all_roots
      Board
        .where(user_id: User::DEFAULT_ADMIN_ID, predefined: true)
        .where("COALESCE((boards.settings->>'#{ROOT_MARKER}')::boolean, false)")
        .order(:id)
    end

    # The seeded root board for a slug, or nil if that set isn't seeded here.
    def find_root(slug)
      return nil if slug.blank?

      all_roots.where("boards.settings->>'#{SLUG_MARKER}' = ?", slug.to_s).first
    end

    # Every admin-owned board in a slug's OBF namespace — the root and all its
    # pages. Same scope VocabSets.prune_removed_boards! sync-owns, so this is
    # exactly the set a re-seed would rewrite, which is what the admin registry
    # needs to report on and repair. Ordered by :id so the root leads.
    def set_boards(slug)
      return Board.none if slug.blank?

      Board.where(user_id: User::DEFAULT_ADMIN_ID)
        .where("obf_id LIKE ?", "#{ActiveRecord::Base.sanitize_sql_like(slug.to_s)}:%")
        .order(:id)
    end

    # The slug stamped on a root board (nil if it isn't a robust-set root).
    def slug_for(board)
      board&.settings&.dig(SLUG_MARKER)
    end

    # The display name for a slug: the authored constant, else a name derived
    # from the slug itself ("core-96" => "Core 96") so a newly authored set works
    # without a code change. Never reads a Board row.
    def display_name_for(slug)
      return nil if slug.blank?

      SET_NAMES[slug.to_s] || slug.to_s.tr("-", " ").titleize
    end

    # Stamp a freshly-seeded root board so the catalog/endpoint can find it.
    def mark_root!(board, slug)
      board.settings = (board.settings || {}).merge(
        ROOT_MARKER => true,
        SLUG_MARKER => slug.to_s,
      )
      board.save!
      board
    end
  end
end
