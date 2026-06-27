module Boards
  # Single source of truth for how many grid columns a board uses on each
  # screen size. The large ("lg") count is authored by the user; the medium
  # and small counts are DERIVED from it so density scales down proportionally
  # for tablets (md) and phones (sm) instead of being fixed values that ignore
  # how dense the lg board is.
  #
  # Rule: md ≈ 2/3 of lg, sm ≈ 1/3 of lg, each rounded and clamped so a tile
  # grid never collapses below a usable width (sm ≥ 2) and the order stays
  # sm ≤ md ≤ lg. The frontend mirrors these fallbacks (NativeLayoutGrid,
  # DraggableGrid) so the viewer, editor, and Speak view all agree.
  module ScreenColumns
    module_function

    # Floor on the smallest screen so phones never drop below a tappable grid.
    SM_MIN = 2

    # Columns for a screen size given the board's authored large-screen count.
    # large_columns is the user-controlled value; md/sm fall out of it.
    def derive(large_columns, screen_size)
      lg = large_columns.to_i
      lg = 1 if lg < 1

      case screen_size.to_s
      when "sm", "xs", "xxs"
        (lg / 3.0).round.clamp([SM_MIN, lg].min, lg)
      when "md"
        sm = derive(lg, "sm")
        ((lg * 2) / 3.0).round.clamp(sm, lg)
      else # "lg" and anything unrecognized
        lg
      end
    end
  end
end
