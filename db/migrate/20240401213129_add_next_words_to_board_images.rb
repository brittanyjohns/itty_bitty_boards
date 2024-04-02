class AddNextWordsToBoardImages < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :next_words, :string, array: true, default: []
    add_column :images, :next_words, :string, array: true, default: []
  end
end
