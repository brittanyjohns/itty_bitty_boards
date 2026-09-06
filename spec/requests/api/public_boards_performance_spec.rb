require "rails_helper"

# Resolving `in_use_by` / `communicator_account_data` walks every ChildBoard
# tying a board to a communicator, reading the account, its profile and that
# profile's avatar attachment per row — so a catalogue board cost queries in
# proportion to how many communicators used it, on an endpoint the Add-boards
# picker fetches. Scoping those fields to the viewer means a caller who is
# entitled to none of them resolves them without a query.
RSpec.describe "API public_boards query cost", type: :request do
  # Collects the real SQL a block runs, ignoring transaction bookkeeping —
  # same shape as spec/models/child_account_api_view_performance_spec.rb.
  def captured_sql
    statements = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      next if sql.match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

      statements << sql
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end

  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  def catalogue_board(name)
    create(:board, user: admin, name: name, predefined: true, published: true)
  end

  def attach_communicators(board, count)
    count.times do
      parent = create(:user)
      account = create(:child_account, user: parent)
      account.child_boards.create!(board: board, created_by_id: parent.id)
    end
  end

  it "never reads the communicator join tables for an unauthenticated caller" do
    board = catalogue_board("Core 60")
    attach_communicators(board, 3)

    # Warm schema/statement caches so the measured request isn't charged for
    # loads a second one would get free.
    get "/api/public_boards"

    statements = captured_sql { get "/api/public_boards" }

    expect(response).to have_http_status(:ok)

    # These fields were the only reason this endpoint touched these tables.
    # Reading them here means the viewer scoping has regressed.
    joins = statements.grep(/child_boards|child_accounts|profiles/i)
    expect(joins).to be_empty, "expected no communicator lookups, got:\n#{joins.join("\n")}"
  end
end
