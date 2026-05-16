class CreateCoachingPhraseAudios < ActiveRecord::Migration[7.1]
  def change
    create_table :coaching_phrase_audios do |t|
      t.text   :text, null: false
      t.string :voice, null: false
      t.string :language, null: false, default: "en"
      t.string :phrase_key, null: false

      t.timestamps
    end

    add_index :coaching_phrase_audios, :phrase_key, unique: true
    add_index :coaching_phrase_audios, [:voice, :language]
  end
end
