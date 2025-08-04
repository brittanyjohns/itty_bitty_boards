class AddColumnSizes < ActiveRecord::Migration[7.1]
  def change
    add_column :board_groups, :small_screen_columns, :integer, default: 4, null: false unless column_exists?(:board_groups, :small_screen_columns)
    add_column :board_groups, :medium_screen_columns, :integer, default: 5, null: false unless column_exists?(:board_groups, :medium_screen_columns)
    add_column :board_groups, :large_screen_columns, :integer, default: 6, null: false unless column_exists?(:board_groups, :large_screen_columns)
    add_column :board_groups, :margin_settings, :jsonb, default: {}, null: false unless column_exists?(:board_groups, :margin_settings)
    add_column :board_groups, :settings, :jsonb, default: {}, null: false unless column_exists?(:board_groups, :settings)
  end
end
