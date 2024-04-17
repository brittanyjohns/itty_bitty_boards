class AddSvgUrlToDocs < ActiveRecord::Migration[7.1]
  def change
    add_column :docs, :original_image_url, :string, default: nil
  end
end
