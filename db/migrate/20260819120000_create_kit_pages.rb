# A reusable lead-magnet landing page served at /kit/:slug. The page's copy,
# its download, and its Mailchimp tag all live here rather than in a frontend
# config file, so adding a campaign page is an admin action instead of a deploy.
#
# The download is an existing BoardPrintable plus a chosen PDF variant — not a
# live board render — so what a visitor gets is the same reviewed document the
# admin looked at.
class CreateKitPages < ActiveRecord::Migration[8.0]
  def change
    create_table :kit_pages do |t|
      t.string :slug, null: false
      t.string :title, null: false
      t.string :eyebrow
      t.text :subhead
      # { "items": [{ "title": ..., "description": ... }],
      #   "closing": { "heading": ..., "body": ..., "cta_label": ..., "cta_path": ... } }
      t.jsonb :content, null: false, default: {}
      # Nullable: a page is drafted before a printable is picked, and it simply
      # renders without the download form until one is.
      t.references :board_printable, foreign_key: true
      t.string :printable_variant, null: false, default: "color"
      # nil means "derive from the slug" — see KitPage#resolved_mailchimp_tag.
      t.string :mailchimp_tag
      t.string :cta_label
      t.string :cta_path
      t.boolean :published, null: false, default: false
      # Stamped only when an admin deliberately confirms giving away a
      # printable that is published on Etsy.
      t.datetime :etsy_override_at
      t.references :etsy_override_by, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :kit_pages, :slug, unique: true
  end
end
