# Text slots and fact-driven overlay regions on scene templates, and the words a
# composition puts in each text slot. The look of a text slot is set once, at
# calibration; a composition supplies only the words. See
# .claude-notes/scene-engine.md.
class AddTextSlotsToSceneTemplates < ActiveRecord::Migration[8.0]
  def change
    add_column :scene_templates, :text_slots, :jsonb, null: false, default: []
    add_column :scene_templates, :overlay_regions, :jsonb, null: false, default: []
    add_column :scene_compositions, :text_values, :jsonb, null: false, default: {}
  end
end
