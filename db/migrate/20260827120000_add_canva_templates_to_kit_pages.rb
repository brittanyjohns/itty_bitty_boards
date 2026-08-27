# Editable Canva template links a kit page hands over alongside (or instead of)
# its PDF. Its own column rather than a key under `content` because
# KitPage#public_view ships `content` wholesale — a template URL parked there
# would leak into the public read, which is the one thing that payload may
# never carry.
class AddCanvaTemplatesToKitPages < ActiveRecord::Migration[8.0]
  def change
    add_column :kit_pages, :canva_templates, :jsonb, default: [], null: false
  end
end
