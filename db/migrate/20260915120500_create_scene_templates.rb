# The shared library of scene templates a product's art is composited into —
# a blank base photo, an optional transparent front layer, and N calibrated
# quads (`slots`). See .claude-notes/scene-engine.md.
class CreateSceneTemplates < ActiveRecord::Migration[8.0]
  def change
    create_table :scene_templates do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.string :category, null: false, default: "board"
      t.string :source, null: false, default: "canva"
      t.string :status, null: false, default: "draft"
      t.integer :width
      t.integer :height
      t.integer :calibration_version, null: false, default: 0
      t.jsonb :slots, null: false, default: []
      t.text :notes
      t.text :prompt

      t.timestamps
    end

    add_index :scene_templates, :slug, unique: true
    add_index :scene_templates, %i[category status]
  end
end
