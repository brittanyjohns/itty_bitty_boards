class CreateAnalyticsEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :analytics_events do |t|
      t.string   :event_type,  null: false
      t.bigint   :user_id
      t.datetime :occurred_at, null: false
      t.jsonb    :metadata,    null: false, default: {}

      t.timestamps
    end

    add_index :analytics_events, :event_type
    add_index :analytics_events, :user_id
    add_index :analytics_events, :occurred_at
    add_index :analytics_events, [:event_type, :occurred_at]
  end
end
