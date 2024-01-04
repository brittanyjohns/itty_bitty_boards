class CreateBoardImages < ActiveRecord::Migration[7.1]
  def change
    create_table :board_images do |t|
      t.belongs_to :board, null: false, foreign_key: true
      t.belongs_to :image, null: false, foreign_key: true
      t.integer :position

      t.timestamps
    end
  end
end
