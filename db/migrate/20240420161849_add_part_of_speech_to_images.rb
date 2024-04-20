class AddPartOfSpeechToImages < ActiveRecord::Migration[7.1]
  def change
    add_column :images, :part_of_speech, :string
    add_column :board_images, :bg_color, :string
    add_column :board_images, :text_color, :string
    add_column :board_images, :font_size, :integer
    add_column :board_images, :border_color, :string
  end
end
