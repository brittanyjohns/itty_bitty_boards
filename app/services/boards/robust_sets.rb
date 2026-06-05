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

    module_function

    # All seeded robust-set ROOT boards (one per set), stable order for the
    # catalog. Empty when nothing is seeded in this environment — callers degrade
    # gracefully (the set just doesn't appear in the picker).
    def all_roots
      Board
        .where("COALESCE((boards.settings->>'#{ROOT_MARKER}')::boolean, false)")
        .order(:name)
    end

    # The seeded root board for a slug, or nil if that set isn't seeded here.
    def find_root(slug)
      return nil if slug.blank?

      all_roots.where("boards.settings->>'#{SLUG_MARKER}' = ?", slug.to_s).first
    end

    # The slug stamped on a root board (nil if it isn't a robust-set root).
    def slug_for(board)
      board&.settings&.dig(SLUG_MARKER)
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
