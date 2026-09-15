# One scene template filled with one product's real art. The owner is
# polymorphic because device tags (#957) composite into the same engine; for
# now it is always a BoardPrintable.
class CreateSceneCompositions < ActiveRecord::Migration[8.0]
  def change
    create_table :scene_compositions do |t|
      t.references :owner, polymorphic: true, null: false
      t.references :board_printable_listing, null: true, foreign_key: { on_delete: :nullify }
      t.references :scene_template, null: false, foreign_key: true
      t.jsonb :slot_art, null: false, default: {}
      t.string :render_digest
      t.datetime :rendered_at
      t.text :error

      t.timestamps
    end
  end
end
