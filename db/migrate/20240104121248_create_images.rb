class CreateImages < ActiveRecord::Migration[7.1]
  def change
    create_table :images do |t|
      t.string :label
      t.text :image_prompt
      t.text :display_description
      t.boolean :private
      t.integer :user_id
      t.boolean :generate_image, default: false

      t.timestamps
    end
  end
end
