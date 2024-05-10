class CreateWordEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :word_events do |t|
      t.belongs_to :user, null: false, foreign_key: true
      t.string :word
      t.string :previous_word
      t.integer :board_id
      t.integer :team_id
      t.datetime :timestamp

      t.timestamps
    end
  end
end
