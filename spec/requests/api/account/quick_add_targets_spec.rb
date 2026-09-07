require "rails_helper"

# The quick-add picker for a COMMUNICATOR token.
#
# Assignment attaches the ROOT of a board set; its folder pages carry no
# child_boards row, so a dashboard-association picker cannot offer the page a
# communicator is standing on. This endpoint offers the reachable set, and it
# reads the same Boards::QuickAddScope that boards#add_image's gate consults —
# so anything listed here is writable and anything missing is refused there.
RSpec.describe "API::Account::QuickAddTargets", type: :request do
  let(:owner) { create(:user) }
  let(:communicator) { create(:child_account, user: owner, name: "Leo") }

  def board(name, user: owner)
    create(:board, user: user, name: name)
  end

  def link(from, to)
    create(:board_image, board: from, predictive_board_id: to.id)
  end

  def attach(board, account)
    create(:child_board, board: board, child_account: account)
  end

  def get_targets
    get "/api/account/quick_add_targets", headers: auth_headers(communicator)
    JSON.parse(response.body)
  end

  it "offers the dashboard root AND the pages hanging off it" do
    root = board("Core 84")
    page = board("Food")
    deep = board("Snacks")
    link(root, page)
    link(page, deep)
    attach(root, communicator)

    body = get_targets

    expect(response).to have_http_status(:ok)
    expect(body["boards"].map { |b| b["name"] })
      .to contain_exactly("Core 84", "Food", "Snacks")
  end

  # Grouping keys on root_board_id, which comes from the walk, and NOT on the
  # stored sub_board column: that one is written by a before_save hook, so a
  # board linked into a set after it was created still reads false until
  # something happens to re-save it. The picker must not depend on that.
  it "groups a page under the root that reaches it" do
    root = board("Core 84")
    page = board("Food")
    link(root, page)
    attach(root, communicator)

    cards = get_targets["boards"].index_by { |b| b["name"] }

    expect(cards["Food"]["root_board_id"]).to eq(root.id)
    expect(cards["Core 84"]["root_board_id"]).to eq(root.id)
  end

  it "carries the stored sub_board flag once the board records it" do
    root = board("Core 84")
    page = board("Food")
    link(root, page)
    page.save! # what check_is_sub_board needs in order to notice the parent
    attach(root, communicator)

    card = get_targets["boards"].find { |b| b["name"] == "Food" }

    expect(card["sub_board"]).to be(true)
  end

  it "reports a sibling-shared board as shared, and still offers it" do
    sibling = create(:child_account, user: owner, name: "Maya")
    root = board("Core 84")
    page = board("Food")
    link(root, page)
    attach(root, communicator)
    attach(root, sibling)

    body = get_targets

    expect(body["boards"].map { |b| b["shared"] }).to all(be(true))
    # Decision: nobody is blocked for sharing. Quick add exists so a
    # nonspeaking person can add a word when they need it.
    post "/api/boards/#{page.id}/add_image",
         params: { image: { label: "pretzel" } },
         headers: auth_headers(communicator)
    expect(response).to have_http_status(:ok)
  end

  it "reports an unshared board as not shared" do
    root = board("Core 84")
    attach(root, communicator)

    expect(get_targets["boards"].first["shared"]).to be(false)
  end

  # A communicator may learn that somebody else uses a board. Never who.
  it "never names another family's communicator" do
    stranger_owner = create(:user)
    stranger_account = create(:child_account, user: stranger_owner, name: "Wilhelmina")
    root = board("Core 84")
    attach(root, communicator)
    attach(root, stranger_account)

    body = get_targets

    expect(body["boards"].first["shared"]).to be(true)
    expect(response.body).not_to include("Wilhelmina")
    keys = body["boards"].flat_map(&:keys).uniq
    expect(keys.grep(/acct_|in_use_by|communicator_account|added_by|email/)).to be_empty
    expect(keys).not_to include("communicator_dashboard_count")
  end

  it "does not offer a board reached only through a tile aimed at another account" do
    victim = board("Someone Else's Board", user: create(:user))
    root = board("Mine")
    link(root, victim)
    attach(root, communicator)

    expect(get_targets["boards"].map { |b| b["id"] }).to eq([root.id])
  end

  it "reports truncation rather than failing" do
    root = board("Core 84")
    page = board("Food")
    link(root, page)
    attach(root, communicator)
    stub_const("Boards::QuickAddScope::MAX_DEPTH", 0)

    body = get_targets

    expect(response).to have_http_status(:ok)
    expect(body["truncated"]).to be(true)
    expect(body["boards"].map { |b| b["id"] }).to eq([root.id])
  end

  it "refuses a user token — this is the communicator surface" do
    get "/api/account/quick_add_targets", headers: auth_headers(owner)

    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses a request carrying no credential" do
    get "/api/account/quick_add_targets"

    expect(response).to have_http_status(:unauthorized)
  end

  # The batching contract, stated as a property rather than a magic number: the
  # cost is a function of DEPTH, not of how many boards come back.
  it "costs the same number of queries for a wide set as a narrow one" do
    def query_count
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
      count
    end

    small_root = board("Small")
    attach(small_root, communicator)
    2.times { |i| link(small_root, board("Small Page #{i}")) }
    small = query_count { get_targets }

    big_root = board("Big")
    attach(big_root, communicator)
    30.times { |i| link(big_root, board("Big Page #{i}")) }
    big = query_count { get_targets }

    expect(big).to eq(small)
  end
end
