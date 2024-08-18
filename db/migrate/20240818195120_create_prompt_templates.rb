class CreatePromptTemplates < ActiveRecord::Migration[7.1]
  def change
    create_table :prompt_templates do |t|
      t.string :prompt_type
      t.string :template_name
      t.string :name
      t.string :response_type
      t.text :prompt_text
      t.text :revised_prompt
      t.text :preprompt_text
      t.string :method_name
      t.boolean :current, default: false
      t.integer :quantity, default: 8
      t.jsonb :config, default: {}

      t.timestamps
    end
    add_column :openai_prompts, :prompt_template_id, :integer
    add_index :openai_prompts, :prompt_template_id
    add_column :openai_prompts, :name, :string
  end
end
