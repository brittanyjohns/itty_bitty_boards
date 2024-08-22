class CreateScenarios < ActiveRecord::Migration[7.1]
  def change
    create_table :scenarios do |t|
      t.json :questions
      t.json :answers
      t.string :name
      t.text :initial_description
      t.string :age_range
      t.references :user, null: false, foreign_key: true
      t.string :status, default: "pending"
      t.string :word_list, array: true, default: []
      t.integer :token_limit, default: 10
      t.integer :board_id
      t.boolean :send_now, default: false
      t.integer :number_of_images, default: 0
      t.integer :tokens_used, default: 0

      t.timestamps
    end
  end
end
