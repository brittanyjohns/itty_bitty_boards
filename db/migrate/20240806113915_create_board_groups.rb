class CreateBoardGroups < ActiveRecord::Migration[7.1]
  def change
    create_table :board_groups do |t|
      t.string :name
      t.jsonb :layout, default: {}
      t.boolean :predefined, default: false
      t.string :display_image_url
      t.integer :position
      t.integer :number_of_columns, default: 6
      t.integer :user_id, null: false
      t.string :bg_color

      t.timestamps
    end
    add_column :boards, :layout, :jsonb, default: {}
    add_column :boards, :position, :integer
    add_column :boards, :audio_url, :string
    add_column :boards, :bg_color, :string
  end
end
