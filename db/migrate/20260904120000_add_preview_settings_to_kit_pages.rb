# Which rendered document page shows where on a /kit/:slug page: not at all, on
# the public page, or only after a visitor hands over an email.
#
# A column rather than blob metadata because RenderKitPreviewsJob destroys and
# recreates every preview blob on each regenerate — a choice stored on the blob
# would be wiped by the next click of "Regenerate". Keyed on the source
# document's blob id plus the page number, which survives a re-render.
#
# An EMPTY hash means "never configured" and resolves to the historical
# behaviour (the first pages of the first document, public), so this column
# changes nothing until an admin picks something.
class AddPreviewSettingsToKitPages < ActiveRecord::Migration[8.0]
  def change
    add_column :kit_pages, :preview_settings, :jsonb, default: {}, null: false
  end
end
