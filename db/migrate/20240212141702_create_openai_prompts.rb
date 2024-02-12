class CreateOpenaiPrompts < ActiveRecord::Migration[7.1]
  def change
    create_table :openai_prompts do |t|
      t.belongs_to :user, null: false, foreign_key: true
      t.text :prompt_text
      t.text :revised_prompt
      t.boolean :send_now, default: false
      t.datetime :deleted_at, default: nil, index: true
      t.datetime :sent_at, default: nil, index: true
      t.boolean :private, default: false
      t.string :age_range
      t.integer :token_limit
      t.string :response_type
      t.text :description
      t.integer :number_of_images, default: 0

      t.timestamps
    end
  end
end
