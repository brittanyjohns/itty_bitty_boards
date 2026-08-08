# The builder never stored a row count on the board it made —
# `Board#rows_for_screen_size` derives rows from the tile count — so "rows" only
# ever meant "columns × rows tiles". Storing the tile count directly says what
# the number actually does and lets a board be sized without pretending its
# height is fixed.
#
# Existing rows hold a ROW count, so the value (and every child page's grid
# override inside `plan`) is converted rather than reinterpreted.
class RenameRowsCountToTileCountOnAdminBoardBuilds < ActiveRecord::Migration[8.0]
  def up
    rename_column :admin_board_builds, :rows_count, :tile_count
    execute("UPDATE admin_board_builds SET tile_count = GREATEST(columns_count * tile_count, 1)")
    convert_child_grids!("rows", "tile_count") { |columns, rows| columns * rows }
  end

  def down
    convert_child_grids!("tile_count", "rows") { |columns, tiles| tiles / [columns, 1].max }
    execute("UPDATE admin_board_builds SET tile_count = GREATEST(tile_count / GREATEST(columns_count, 1), 1)")
    rename_column :admin_board_builds, :tile_count, :rows_count
  end

  private

  # A child page's grid override lives in the `plan` jsonb, not in a column, so
  # it has to be rewritten row by row. The table is admin-authored builds — tens
  # of rows, not millions.
  def convert_child_grids!(from_key, to_key)
    select_all("SELECT id, columns_count, plan FROM admin_board_builds").each do |row|
      plan = row["plan"].is_a?(String) ? JSON.parse(row["plan"].presence || "{}") : (row["plan"] || {})
      # Only an authored override is converted — a blank one inherits the root's
      # grid and must stay blank, or every page becomes independently sized.
      overrides = Array(plan["children"]).select { |child| child[from_key].present? }
      next if overrides.empty?

      root_columns = row["columns_count"].to_i
      overrides.each do |child|
        columns = child["columns"].presence&.to_i || root_columns
        child[to_key] = [yield(columns, child.delete(from_key).to_i), 1].max
      end

      execute("UPDATE admin_board_builds SET plan = #{quote(plan.to_json)}::jsonb WHERE id = #{row["id"].to_i}")
    end
  end
end
