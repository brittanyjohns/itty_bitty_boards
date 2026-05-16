class CreateCoachingPromptSets < ActiveRecord::Migration[7.1]
  def change
    create_table :coaching_prompt_sets do |t|
      t.string  :name, null: false
      t.string  :slug, null: false
      t.text    :description
      t.jsonb   :strategies, null: false, default: []
      t.string  :match_tags, array: true, default: []
      t.string  :source, null: false, default: "curated"
      t.bigint  :user_id
      t.boolean :published, null: false, default: true
      t.string  :language, null: false, default: "en"

      t.timestamps
    end

    add_index :coaching_prompt_sets, :slug, unique: true
    add_index :coaching_prompt_sets, :user_id
    add_index :coaching_prompt_sets, :match_tags, using: "gin"
    add_index :coaching_prompt_sets, [:source, :published]
  end
end
