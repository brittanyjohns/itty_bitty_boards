class CreateMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :messages do |t|
      t.string :subject
      t.text :body
      t.integer :user_id
      t.string :user_email

      t.timestamps
    end
  end
end
