class CreateBoardTags < ActiveRecord::Migration[7.1]
  def change
    create_table :tags do |t|
      t.string :name
    end

    create_table :board_tags do |t|
      t.references :board
      t.references :tag
      t.timestamps
    end
    add_column :boards, :metadata, :jsonb, default: {}
    add_index :boards, :metadata, using: :gin
  end
end
