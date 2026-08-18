class AddWordEventLookupIndexes < ActiveRecord::Migration[8.0]
  # CONCURRENTLY can't run inside a transaction. word_events is the hottest
  # append-only table in the app (~140k rows in production and growing), and
  # these indexes back a request-path read, so take the slower build over an
  # exclusive lock on writes.
  disable_ddl_transaction!

  def change
    # `ChildAccount#boards_by_most_used` does `GROUP BY board_id` over an
    # account's whole history, and `recently_used_boards` filters on it.
    # There was no index on this column at all.
    add_index :word_events, :board_id, algorithm: :concurrently, if_not_exists: true

    # Every range query (week_chart_data, most_clicked_words,
    # word_events_summary, part_of_speech_breakdown, and the stats endpoint)
    # filters child_account_id AND timestamp. The existing single-column
    # child_account_id index makes Postgres walk the account's entire history
    # and discard by date; the composite lets it seek straight to the window.
    add_index :word_events, [:child_account_id, :timestamp], algorithm: :concurrently, if_not_exists: true
  end
end
