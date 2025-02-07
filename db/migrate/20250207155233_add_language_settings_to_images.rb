class AddLanguageSettingsToImages < ActiveRecord::Migration[7.1]
  def up
    add_column :images, :language_settings, :jsonb, default: {}
    add_column :images, :language, :string, default: "en"
    add_column :boards, :language, :string, default: "en"
    add_column :board_images, :language, :string, default: "en"
    add_column :board_images, :display_label, :string
    add_column :board_images, :language_settings, :jsonb, default: {}
    Image.where(language_settings: {}).each do |image|
      default_language_settings = {
        "en": {
          "display_label": image.display_label,
          "label": image.label,
        },
      }
      image.update!(language_settings: default_language_settings, language: "en")
    end
    BoardImage.includes(:board).where(language_settings: {}).each do |board_image|
      board = board_image.board
      default_language_settings = {
        "en": {
          "display_label": board_image.display_label || board_image.label,
          "label": board_image.label,
        },
      }
      board_image.update!(language_settings: default_language_settings, language: "en")

      board.update!(language: "en")
    end
  end

  def down
    remove_column :images, :language_settings
    remove_column :images, :language
    remove_column :boards, :language
    remove_column :board_images, :language
    remove_column :board_images, :display_label
    remove_column :board_images, :language_settings
  end
end
