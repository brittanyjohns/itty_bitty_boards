class CreateUserDocs < ActiveRecord::Migration[7.1]
  def change
    create_table :user_docs do |t|
      t.belongs_to :user, null: false, foreign_key: true
      t.belongs_to :doc, null: false, foreign_key: true
      t.integer :image_id

      t.timestamps
    end
  end
end
