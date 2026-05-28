class EnableUnaccentAndIndexLanguageSettings < ActiveRecord::Migration[7.0]
  def up
    enable_extension "unaccent" unless extension_enabled?("unaccent")

    return if index_exists?(:images, :language_settings, name: "index_images_on_language_settings_gin")

    add_index :images,
              :language_settings,
              using: :gin,
              name: "index_images_on_language_settings_gin"
  end

  def down
    if index_exists?(:images, :language_settings, name: "index_images_on_language_settings_gin")
      remove_index :images, name: "index_images_on_language_settings_gin"
    end
  end
end
