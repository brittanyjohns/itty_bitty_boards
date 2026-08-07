# Keeps the Postgres `users` primary-key sequence clear of the ids specs pin
# by hand.
#
# Several specs have to insert the seed admin at an explicit primary key
# (`User::DEFAULT_ADMIN_ID`) because services look it up by that id. An
# explicit-id INSERT does not advance `users_id_seq`, and sequences are not
# rolled back with the surrounding transaction — so on a freshly prepared
# database (CI, or a local `db:test:prepare`) the sequence still points at
# DEFAULT_ADMIN_ID after the pinned insert, and the next factory-built user is
# handed that same id:
#
#   PG::UniqueViolation: duplicate key value violates unique constraint
#   "users_pkey" DETAIL: Key (id)=(1) already exists.
#
# Whether it blows up depends entirely on spec order, which makes it a
# recurring, hard-to-place CI failure rather than a reproducible one.
#
# The fix is headroom, not bookkeeping at the call sites: park the sequence
# far above every id a spec pins, so a hand-picked id and a sequence-issued id
# can never be the same number. Two rails matter here:
#
#   * The floor is well above DEFAULT_ADMIN_ID, not one step above it. Sitting
#     exactly at MAX(id) leaves zero slack, so any row the `MAX(id)` probe
#     can't see — one inserted later in the same example, or from a
#     `before(:all)` block — lands right back on the next sequence value.
#   * The guard is monotonic. It never moves the sequence backwards, so it can
#     only ever widen the gap, and re-running it is always safe.
module UsersIdSequence
  # Well clear of User::DEFAULT_ADMIN_ID (1) and of any id a spec pins by hand.
  FLOOR = 10_000

  # A single statement per call: leave the sequence at the highest of (where it
  # already is, the largest id in the table, the floor). `pg_sequence_last_value`
  # is NULL until the sequence has been advanced, which the COALESCE turns into
  # 0 so a never-used sequence jumps straight to the floor.
  ENSURE_SQL = <<~SQL.freeze
    SELECT setval(
      pg_get_serial_sequence('users', 'id'),
      GREATEST(
        COALESCE(pg_sequence_last_value(pg_get_serial_sequence('users', 'id')::regclass), 0),
        COALESCE((SELECT MAX(id) FROM users), 0),
        #{FLOOR}
      ),
      true
    )
  SQL

  def self.ensure_clear!
    ActiveRecord::Base.connection.execute(ENSURE_SQL)
  end

  # The id nextval would hand out right now, without consuming it. A sequence
  # that has never been advanced (is_called = false) returns last_value itself.
  def self.next_id
    connection = ActiveRecord::Base.connection
    sequence = connection.select_value("SELECT pg_get_serial_sequence('users', 'id')")
    row = connection.select_one("SELECT last_value, is_called FROM #{sequence}")
    row["is_called"] ? row["last_value"].to_i + 1 : row["last_value"].to_i
  end
end

RSpec.configure do |config|
  config.before(:suite) { UsersIdSequence.ensure_clear! }

  # `before(:context)` covers test_prof's `before_all` / `let_it_be`, which
  # create records before any example-level hook has run.
  config.before(:context) { UsersIdSequence.ensure_clear! }
  config.before(:each) { UsersIdSequence.ensure_clear! }
end
