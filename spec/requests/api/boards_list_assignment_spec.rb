require "rails_helper"

# /api/boards/list feeds the board picker ("Pick a board to open"). Two boards
# can share a name — a source board and the clone sitting on a communicator —
# so the picker needs to say which communicator each one belongs to. This is
# the payload behind that label.
RSpec.describe "API boards list assignment", type: :request do
  # Collects the real SQL a block runs, ignoring transaction bookkeeping —
  # same shape as spec/requests/api/public_boards_performance_spec.rb.
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

  let!(:user) { create(:user) }

  def board_row(name)
    JSON.parse(response.body).fetch("boards").find { |b| b["name"] == name }
  end

  it "names the communicator a board is attached to directly" do
    board = create(:board, user: user, name: "Snack Time")
    account = create(:child_account, user: user, name: "Austin")
    account.child_boards.create!(board: board, created_by_id: user.id)

    get "/api/boards/list", headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(board_row("Snack Time")["in_use_by"]).to eq("Austin")
  end

  it "names the communicator through the clone-source join too" do
    source = create(:board, user: user, name: "Core 60")
    clone  = create(:board, user: user, name: "Core 60")
    account = create(:child_account, user: user, name: "Austin")
    account.child_boards.create!(board: clone, original_board_id: source.id, created_by_id: user.id)

    get "/api/boards/list", headers: auth_headers(user)

    rows = JSON.parse(response.body).fetch("boards").select { |b| b["name"] == "Core 60" }
    expect(rows.map { |b| b["in_use_by"] }).to all(eq("Austin"))
  end

  it "joins every communicator sharing one board" do
    board = create(:board, user: user, name: "Playground")
    ["Austin", "Mia"].each do |name|
      create(:child_account, user: user, name: name)
        .child_boards.create!(board: board, created_by_id: user.id)
    end

    get "/api/boards/list", headers: auth_headers(user)

    expect(board_row("Playground")["in_use_by"].split(", ")).to match_array(%w[Austin Mia])
  end

  it "leaves in_use_by nil for a board no communicator uses" do
    create(:board, user: user, name: "Draft Board")

    get "/api/boards/list", headers: auth_headers(user)

    expect(board_row("Draft Board")["in_use_by"]).to be_nil
  end

  # The picker label is "assigned to a communicator YOU own". Someone else's
  # communicator using a board of yours is not the viewer's name to see.
  it "does not name another account's communicator" do
    board = create(:board, user: user, name: "Shared Board")
    stranger = create(:user)
    create(:child_account, user: stranger, name: "Not Yours")
      .child_boards.create!(board: board, created_by_id: stranger.id)

    get "/api/boards/list", headers: auth_headers(user)

    expect(board_row("Shared Board")["in_use_by"]).to be_nil
  end

  # The admin owns the predefined public library, so their boards are cloned
  # onto strangers' communicators by the hundred. Widening for admins the way
  # the boards grid does would name all of them in this label.
  it "does not widen to every communicator for an admin viewer" do
    admin = create(:admin_user)
    board = create(:board, user: admin, name: "Predefined Core")
    stranger = create(:user)
    create(:child_account, user: stranger, name: "Not Yours")
      .child_boards.create!(board: board, created_by_id: stranger.id)
    create(:child_account, user: admin, name: "Austin")
      .child_boards.create!(board: board, created_by_id: admin.id)

    get "/api/boards/list", headers: auth_headers(admin)

    expect(board_row("Predefined Core")["in_use_by"]).to eq("Austin")
  end

  it "resolves the whole list's assignments in one read of the join table" do
    5.times do |n|
      board = create(:board, user: user, name: "Board #{n}")
      create(:child_account, user: user, name: "Kid #{n}")
        .child_boards.create!(board: board, created_by_id: user.id)
    end

    # Warm schema/statement caches so the measured request isn't charged for
    # loads a second one would get free.
    get "/api/boards/list", headers: auth_headers(user)

    statements = captured_sql { get "/api/boards/list", headers: auth_headers(user) }

    expect(response).to have_http_status(:ok)
    child_board_reads = statements.select { |sql| sql.include?("child_boards") }
    # One for the serialized names, plus the ETag's assignment terms — and not
    # a pair per board, which is what `in_use_by` costs on its own.
    expect(child_board_reads.size).to be <= 3
  end

  # Board#recalculate_in_use! flips the flag with update_column, so assigning a
  # board never bumps boards.updated_at. Without the ETag's communicator terms
  # the next request 304s and the picker keeps showing the pre-assignment list.
  it "revalidates the cached list after a board is assigned" do
    board = create(:board, user: user, name: "Bath Time")

    get "/api/boards/list", headers: auth_headers(user)
    etag = response.headers["ETag"]
    expect(etag).to be_present

    create(:child_account, user: user, name: "Austin")
      .child_boards.create!(board: board, created_by_id: user.id)

    get "/api/boards/list", headers: auth_headers(user).merge("If-None-Match" => etag)

    expect(response).to have_http_status(:ok)
    expect(board_row("Bath Time")["in_use_by"]).to eq("Austin")
  end

  # A rename touches no board row at all.
  it "revalidates the cached list after a communicator is renamed" do
    board = create(:board, user: user, name: "Bedtime")
    account = create(:child_account, user: user, name: "Austin")
    account.child_boards.create!(board: board, created_by_id: user.id)

    get "/api/boards/list", headers: auth_headers(user)
    etag = response.headers["ETag"]

    account.update!(name: "Austin R.")

    get "/api/boards/list", headers: auth_headers(user).merge("If-None-Match" => etag)

    expect(response).to have_http_status(:ok)
    expect(board_row("Bedtime")["in_use_by"]).to eq("Austin R.")
  end
end
