class AddDrawingFieldsToEventsAndEntries < ActiveRecord::Migration[8.0]
  def change
    # Winner history: set on every win, never cleared, so a redraw keeps the
    # full story in the CSV. brittanyjohns/itty_bitty_boards#909
    add_column :contest_entries, :won_at, :datetime
    # Staff / test entries: never eligible to win.
    add_column :contest_entries, :excluded, :boolean, default: false, null: false
    add_index :contest_entries, :excluded

    # Drawing grouping ("one prize per person across the CTG days") and the
    # time zone the event's calendar day is measured in.
    add_column :events, :lead_source, :string
    add_column :events, :time_zone, :string, default: "America/Chicago", null: false
    add_index :events, :lead_source
  end
end
