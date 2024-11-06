class AddLabelToBoardImages < ActiveRecord::Migration[7.1]
  def change
    add_column :board_images, :label, :string
    add_index :board_images, :label

    BoardImage.includes(:image).all.each do |bi|
      bi.update(label: bi.image.label)
    end
  end
end
