module Boards
  # Picks the grid width that makes the squarest, tightest grid for a known
  # tile count. A menu board's tile count isn't known until the vision result
  # has been turned into tiles, so its columns are chosen from the real count
  # here rather than guessed at board-create time.
  #
  # Boards::ScreenColumns stays the authority for deriving md/sm from the
  # large-screen count this returns.
  module GridFit
    module_function

    MIN_COLUMNS = 2
    # Ceiling on the large-screen grid so a long menu gets taller, not
    # narrower-per-tile than a finger can hit on a tablet.
    MAX_COLUMNS = 8

    def columns_for(tile_count, min_columns: MIN_COLUMNS, max_columns: MAX_COLUMNS)
      count = tile_count.to_i
      return min_columns if count < 1

      ideal = Math.sqrt(count).ceil
      low = [ideal - 2, min_columns].max
      high = [[ideal + 2, max_columns].min, low].max

      # Lowest score wins; ties go to the wider grid, since screens are landscape.
      (low..high).min_by { |columns| [score(count, columns), -columns] }
    end

    # Empty trailing cells cost 1 each; every step away from square costs 2,
    # so "square with a couple of gaps" beats "exact fit but a long strip".
    def score(count, columns)
      rows = (count / columns.to_f).ceil
      empty = (columns * rows) - count
      empty + (2 * (columns - rows).abs)
    end
  end
end
