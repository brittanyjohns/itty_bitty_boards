class AddBuilderToBoardGroups < ActiveRecord::Migration[7.1]
  # Marks a BoardGroup as Board Builder output (the canonical container for a
  # built set). Gates the builder-only counting + cascade-delete behavior so
  # hand-made groups are unchanged. Consistent with the existing
  # predefined/featured boolean flags; a real column over a settings JSONB key
  # because the JSONB-flag fragility is exactly what this work removes.
  def change
    add_column :board_groups, :builder, :boolean, default: false, null: false
    add_index  :board_groups, :builder
  end
end
