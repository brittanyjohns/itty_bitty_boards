class CreateDynamicBoards < ActiveRecord::Migration[7.1]
  def change
    create_table :dynamic_boards do |t|
      t.string :name
      t.integer :user_id
      t.integer :parent_id
      t.string :parent_type
      t.text "description"
      t.integer "cost", default: 0
      t.boolean "predefined", default: false
      t.integer "token_limit", default: 0
      t.string "voice", default: "echo"
      t.string "status", default: "pending"
      t.integer "number_of_columns", default: 6
      t.integer "small_screen_columns", default: 3
      t.integer "medium_screen_columns", default: 8
      t.integer "large_screen_columns", default: 12
      t.string "display_image_url"
      t.jsonb "layout", default: {}
      t.integer "position"
      t.string "audio_url"
      t.string "bg_color"

      t.timestamps
    end
    add_index :dynamic_boards, :user_id
    add_index :dynamic_boards, :name
    add_index :dynamic_boards, [:parent_id, :parent_type]
  end
end
