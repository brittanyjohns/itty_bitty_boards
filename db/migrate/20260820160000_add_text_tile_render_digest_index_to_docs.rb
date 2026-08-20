class AddTextTileRenderDigestIndexToDocs < ActiveRecord::Migration[8.0]
  # Images::TextTile::Creator looks a render up by digest before forking
  # Chrome. Partial: text tiles are a sliver of docs, and only they carry the
  # key.
  disable_ddl_transaction!

  def change
    add_index :docs,
              "(data->>'render_digest')",
              name: "index_docs_on_text_tile_render_digest",
              where: "source_type = 'SpeakAnyWayText'",
              algorithm: :concurrently
  end
end
