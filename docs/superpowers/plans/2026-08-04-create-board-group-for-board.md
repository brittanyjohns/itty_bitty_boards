# Create a Board Group (map) for any linked board — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a board's owner (or admin) create a `BoardGroup` for it on demand — auto-populated with every board reachable via folder links — so the "set map" becomes available even for boards never built via the Board Builder wizard.

**Architecture:** Extract the existing BFS traversal in `Boards::SetGraphBuilder` into a shared `Boards::LinkedBoardsFinder` service. Add a `Boards::BoardGroupCreator` service that reuses it to build (or find-and-reuse) a `BoardGroup` for a board. Expose it via a new `POST /api/boards/:id/create_board_group` member route.

**Tech Stack:** Ruby on Rails 8, RSpec, FactoryBot.

## Global Constraints

- Standard Ruby style, fat models/thin controllers, snake_case (repo `CLAUDE.md`).
- Never expose internal errors in API responses — generic messages only.
- New features get tests; don't backfill tests for unrelated existing code.
- Reuse the existing 422 board-set-limit contract: `{ error, limit, count }` (see `Api::BoardGroupsController#create` and `Api::V1::BoardBuilderController#create`).
- Reuse the existing eligible-group rule the frontend already applies (`builder: true` OR non-predefined owned group) so the new endpoint never creates a duplicate group for a board that already has a working map.

---

### Task 1: Extract `Boards::LinkedBoardsFinder` from `SetGraphBuilder`

**Files:**
- Create: `app/services/boards/linked_boards_finder.rb`
- Modify: `app/services/boards/set_graph_builder.rb:68-87` (replace `bfs_boards_from_root` body with a delegation)
- Test: `spec/services/boards/linked_boards_finder_spec.rb`

**Interfaces:**
- Produces: `Boards::LinkedBoardsFinder.new(root_board).call` → `Array<Board>`, BFS over `board_images.predictive_board_id` starting at `root_board`, root included, capped at `Boards::LinkedBoardsFinder::MAX_BOARDS` (500, same cap `SetGraphBuilder` used), each board `includes(board_images: :image)`.

- [ ] **Step 1: Write the failing test**

```ruby
require "rails_helper"

RSpec.describe Boards::LinkedBoardsFinder do
  let(:user) { FactoryBot.create(:user) }

  def add_tile(board, label:, links_to: nil)
    image = FactoryBot.create(:image, label: label)
    FactoryBot.create(:board_image, board: board, image: image, predictive_board_id: links_to&.id)
  end

  it "returns the root plus every board reachable via folder links" do
    home  = FactoryBot.create(:board, user: user, name: "Home")
    food  = FactoryBot.create(:board, user: user, name: "Food")
    fruit = FactoryBot.create(:board, user: user, name: "Fruit")
    orphan = FactoryBot.create(:board, user: user, name: "Orphan")

    add_tile(home, label: "Food", links_to: food)
    add_tile(food, label: "Fruit", links_to: fruit)
    add_tile(orphan, label: "lonely")

    result = described_class.new(home).call
    expect(result.map(&:id)).to contain_exactly(home.id, food.id, fruit.id)
  end

  it "does not loop forever on a cycle" do
    a = FactoryBot.create(:board, user: user, name: "A")
    b = FactoryBot.create(:board, user: user, name: "B")
    add_tile(a, label: "to b", links_to: b)
    add_tile(b, label: "to a", links_to: a)

    result = described_class.new(a).call
    expect(result.map(&:id)).to contain_exactly(a.id, b.id)
  end

  it "returns just the root when it links to nothing" do
    solo = FactoryBot.create(:board, user: user, name: "Solo")
    add_tile(solo, label: "word")

    result = described_class.new(solo).call
    expect(result.map(&:id)).to contain_exactly(solo.id)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/boards/linked_boards_finder_spec.rb`
Expected: FAIL — `uninitialized constant Boards::LinkedBoardsFinder`

- [ ] **Step 3: Write the implementation**

```ruby
module Boards
  # BFS over folder→child links (board_images.predictive_board_id) starting
  # at a given board. Used by Boards::SetGraphBuilder (root-BFS fallback for
  # sets that predate #407's board_group membership backfill) and by
  # Boards::BoardGroupCreator (auto-populating a brand new group).
  class LinkedBoardsFinder
    # Defensive hard cap so a cyclic/garbage tree can't spin forever.
    MAX_BOARDS = 500

    def initialize(root_board)
      @root_board = root_board
    end

    def call
      return [] if root_board.blank?

      visited = {}
      queue = [root_board.id]
      until queue.empty? || visited.size >= MAX_BOARDS
        board_id = queue.shift
        next if visited.key?(board_id)

        board = Board.includes(board_images: :image).find_by(id: board_id)
        next unless board

        visited[board_id] = board
        board.board_images.each do |bi|
          target = bi.predictive_board_id
          queue << target if target.present? && target != bi.board_id && !visited.key?(target)
        end
      end
      visited.values
    end

    private

    attr_reader :root_board
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/services/boards/linked_boards_finder_spec.rb`
Expected: PASS (3 examples)

- [ ] **Step 5: Point `SetGraphBuilder` at the new service and re-run its existing spec**

Replace `app/services/boards/set_graph_builder.rb:68-87`:

```ruby
    def bfs_boards_from_root
      return [] if root_board_id.blank?

      root_board = Board.find_by(id: root_board_id)
      Boards::LinkedBoardsFinder.new(root_board).call
    end
```

(Delete the old BFS body — `MAX_BOARDS` constant on `SetGraphBuilder` can stay or go; if kept elsewhere unused, remove it since `LinkedBoardsFinder::MAX_BOARDS` now owns the cap.)

Run: `bundle exec rspec spec/services/boards/set_graph_builder_spec.rb`
Expected: PASS (no behavior change — same test suite as before, all green)

- [ ] **Step 6: Commit**

```bash
git add app/services/boards/linked_boards_finder.rb app/services/boards/set_graph_builder.rb spec/services/boards/linked_boards_finder_spec.rb
git commit -m "refactor(boards): extract folder-link BFS into Boards::LinkedBoardsFinder"
```

---

### Task 2: `Board#eligible_board_group` helper

**Files:**
- Modify: `app/models/board.rb` (add near `builder_board_group`, `app/models/board.rb:237-241`)
- Test: `spec/models/board_eligible_board_group_spec.rb`

**Interfaces:**
- Consumes: `board_groups` association (`app/models/board.rb:67`), `BoardGroup.builder` scope (`app/models/board_group.rb:38`).
- Produces: `board.eligible_board_group` → `BoardGroup | nil`. Mirrors the frontend's `eligibleSets()` rule (`src/components/boards/ViewSetMapButton.tsx`): a `builder: true` group, or any non-predefined group, in that preference order.

- [ ] **Step 1: Write the failing test**

```ruby
require "rails_helper"

RSpec.describe Board, "#eligible_board_group" do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user) }

  it "returns nil when the board belongs to no group" do
    expect(board.eligible_board_group).to be_nil
  end

  it "returns a builder group over a non-predefined group when both exist" do
    plain_group = create(:board_group, user: user, builder: false, predefined: false)
    plain_group.add_board(board)
    builder_group = create(:board_group, user: user, builder: true)
    builder_group.add_board(board)

    expect(board.eligible_board_group).to eq(builder_group)
  end

  it "returns a non-predefined, non-builder group" do
    group = create(:board_group, user: user, builder: false, predefined: false)
    group.add_board(board)

    expect(board.eligible_board_group).to eq(group)
  end

  it "ignores a predefined, non-builder group" do
    group = create(:board_group, user: user, builder: false, predefined: true)
    group.add_board(board)

    expect(board.eligible_board_group).to be_nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/board_eligible_board_group_spec.rb`
Expected: FAIL — `undefined method 'eligible_board_group'`

- [ ] **Step 3: Write the implementation**

Add to `app/models/board.rb`, right after `builder_board_group` (`app/models/board.rb:241`):

```ruby
  # The BoardGroup a "view/create set map" action should use for this board,
  # mirroring the frontend's eligibleSets() rule in ViewSetMapButton.tsx: a
  # builder set takes priority (that's what the map is built for), otherwise
  # any user-owned non-predefined set. nil when the board has neither.
  def eligible_board_group
    board_groups.where(builder: true).first ||
      board_groups.where(predefined: [false, nil]).first
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/models/board_eligible_board_group_spec.rb`
Expected: PASS (4 examples)

- [ ] **Step 5: Commit**

```bash
git add app/models/board.rb spec/models/board_eligible_board_group_spec.rb
git commit -m "feat(boards): add Board#eligible_board_group helper"
```

---

### Task 3: `Boards::BoardGroupCreator` service

**Files:**
- Create: `app/services/boards/board_group_creator.rb`
- Test: `spec/services/boards/board_group_creator_spec.rb`

**Interfaces:**
- Consumes: `Boards::LinkedBoardsFinder.new(board).call` (Task 1), `Board#eligible_board_group` (Task 2), `BoardGroup#add_board` (`app/models/board_group.rb:156`), `User#at_board_group_limit?` (`app/models/user.rb:1830`).
- Produces: `Boards::BoardGroupCreator.new(board: board, user: user).call` → `BoardGroup`. Raises `Boards::BoardGroupCreator::LimitReached` (a plain `StandardError` subclass) when `user.at_board_group_limit?` and no eligible group already exists.

- [ ] **Step 1: Write the failing test**

```ruby
require "rails_helper"

RSpec.describe Boards::BoardGroupCreator do
  let(:user) { create(:user) }

  def add_tile(board, label:, links_to: nil)
    image = FactoryBot.create(:image, label: label)
    FactoryBot.create(:board_image, board: board, image: image, predictive_board_id: links_to&.id)
  end

  describe "when the board has no eligible group yet" do
    it "creates a new group rooted at the board with every reachable board as a member" do
      home = create(:board, user: user, name: "Home")
      food = create(:board, user: user, name: "Food")
      add_tile(home, label: "Food", links_to: food)
      add_tile(food, label: "apple")

      group = described_class.new(board: home, user: user).call

      expect(group).to be_persisted
      expect(group.root_board_id).to eq(home.id)
      expect(group.name).to eq("Home")
      expect(group.builder).to be(false)
      expect(group.boards.map(&:id)).to contain_exactly(home.id, food.id)
    end
  end

  describe "when the board already has an eligible group" do
    it "returns the existing group instead of creating a duplicate" do
      home = create(:board, user: user, name: "Home")
      existing = create(:board_group, user: user, builder: true)
      existing.add_board(home)

      expect {
        result = described_class.new(board: home, user: user).call
        expect(result).to eq(existing)
      }.not_to change(BoardGroup, :count)
    end
  end

  describe "when the user is at their board-group limit" do
    before { user.update!(settings: (user.settings || {}).merge("board_group_limit" => 0)) }

    it "raises LimitReached and creates nothing" do
      home = create(:board, user: user, name: "Home")

      expect {
        described_class.new(board: home, user: user).call
      }.to raise_error(Boards::BoardGroupCreator::LimitReached)
      expect(BoardGroup.count).to eq(0)
    end

    it "still returns the existing group without raising, even at the limit" do
      home = create(:board, user: user, name: "Home")
      existing = create(:board_group, user: user, builder: true)
      existing.add_board(home)

      expect { described_class.new(board: home, user: user).call }.not_to raise_error
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/boards/board_group_creator_spec.rb`
Expected: FAIL — `uninitialized constant Boards::BoardGroupCreator`

- [ ] **Step 3: Write the implementation**

```ruby
module Boards
  # Creates (or reuses) a BoardGroup for a board so its "set map" becomes
  # available, even when the board was never built via the Board Builder
  # wizard and so never got a builder: true group automatically.
  class BoardGroupCreator
    class LimitReached < StandardError; end

    def initialize(board:, user:)
      @board = board
      @user = user
    end

    def call
      existing = board.eligible_board_group
      return existing if existing

      raise LimitReached if user.at_board_group_limit?

      create_group!
    end

    private

    attr_reader :board, :user

    def create_group!
      members = Boards::LinkedBoardsFinder.new(board).call
      group = nil
      ActiveRecord::Base.transaction do
        group = BoardGroup.create!(user: user, name: board.name, builder: false, root_board_id: board.id)
        members.each { |member| group.add_board(member) }
      end
      group
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/services/boards/board_group_creator_spec.rb`
Expected: PASS (4 examples)

- [ ] **Step 5: Commit**

```bash
git add app/services/boards/board_group_creator.rb spec/services/boards/board_group_creator_spec.rb
git commit -m "feat(boards): add Boards::BoardGroupCreator service"
```

---

### Task 4: `POST /api/boards/:id/create_board_group` endpoint

**Files:**
- Modify: `config/routes.rb:284-312` (add member route)
- Modify: `app/controllers/api/boards_controller.rb` (add `create_board_group` action, near `clone` at `app/controllers/api/boards_controller.rb:1163-1171`)
- Test: `spec/requests/api/boards_create_board_group_spec.rb`

**Interfaces:**
- Consumes: `Boards::BoardGroupCreator.new(board:, user:).call` (Task 3), `BoardGroup#api_view_with_boards(viewing_user)` (`app/models/board_group.rb:260`), `set_board` (`app/controllers/api/boards_controller.rb:1422-1433`).
- Produces: route `create_board_group_api_board_path(id)` → `POST /api/boards/:id/create_board_group`.

- [ ] **Step 1: Add the route**

In `config/routes.rb`, inside the `resources :boards do ... member do ... end end` block (`config/routes.rb:284-312`), add alongside `post "clone"`:

```ruby
        post "create_board_group"
```

- [ ] **Step 2: Write the failing request spec**

```ruby
require "rails_helper"

RSpec.describe "API::Boards#create_board_group", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  def add_tile(board, label:, links_to: nil)
    image = FactoryBot.create(:image, label: label)
    FactoryBot.create(:board_image, board: board, image: image, predictive_board_id: links_to&.id)
  end

  let!(:home) { create(:board, user: user, name: "Home") }
  let!(:food) { create(:board, user: user, name: "Food") }

  before { add_tile(home, label: "Food", links_to: food) }

  it "creates a group for the board and returns it" do
    post "/api/boards/#{home.id}/create_board_group", headers: auth_headers(user)

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body["root_board_id"]).to eq(home.id)
    board_ids = body["boards"].map { |b| b["id"] }
    expect(board_ids).to contain_exactly(home.id, food.id)
  end

  it "returns the existing group (200) instead of duplicating it" do
    existing = home.board_groups.create!(user: user, name: "Existing", builder: true)
    existing.add_board(home)

    post "/api/boards/#{home.id}/create_board_group", headers: auth_headers(user)

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["id"]).to eq(existing.id)
  end

  it "returns 401 for a non-owner, non-admin user" do
    post "/api/boards/#{home.id}/create_board_group", headers: auth_headers(other_user)

    expect(response).to have_http_status(:unauthorized)
    expect(BoardGroup.where(root_board_id: home.id)).to be_empty
  end

  it "returns the standard board-set-limit 422 shape when the user is at their limit" do
    user.update!(settings: (user.settings || {}).merge("board_group_limit" => 0))

    post "/api/boards/#{home.id}/create_board_group", headers: auth_headers(user)

    expect(response).to have_http_status(:unprocessable_content)
    body = JSON.parse(response.body)
    expect(body["error"]).to be_present
    expect(body).to have_key("limit")
    expect(body).to have_key("count")
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bundle exec rspec spec/requests/api/boards_create_board_group_spec.rb`
Expected: FAIL — routing error (`No route matches [POST] "/api/boards/.../create_board_group"`)

- [ ] **Step 4: Write the controller action**

Add to `app/controllers/api/boards_controller.rb`, right after `clone` (`app/controllers/api/boards_controller.rb:1171`):

```ruby
  def create_board_group
    set_board
    return if @board.nil? # set_board already rendered 404

    unless @board.user_id == current_user.id || current_user.admin?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    existing = @board.eligible_board_group
    board_group = Boards::BoardGroupCreator.new(board: @board, user: current_user).call
    status = existing ? :ok : :created
    render json: board_group.api_view_with_boards(current_user), status: status
  rescue Boards::BoardGroupCreator::LimitReached
    render json: {
      error: "You've reached your plan's board set limit. Upgrade to create more.",
      limit: current_user.board_group_limit,
      count: current_user.countable_board_group_count,
    }, status: :unprocessable_content
  end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/requests/api/boards_create_board_group_spec.rb`
Expected: PASS (4 examples)

- [ ] **Step 6: Run the full boards + board_groups request/service suites to check for regressions**

Run: `bundle exec rspec spec/requests/api/boards_spec.rb spec/requests/api/board_groups_spec.rb spec/services/boards/ spec/models/board_eligible_board_group_spec.rb spec/requests/api/boards_create_board_group_spec.rb spec/requests/api/boards_destroy_spec.rb`
Expected: all PASS, zero failures

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/api/boards_controller.rb spec/requests/api/boards_create_board_group_spec.rb
git commit -m "feat(boards): add POST /api/boards/:id/create_board_group endpoint"
```

---

## Self-Review Notes

- **Spec coverage:** `Boards::LinkedBoardsFinder` (Task 1) ↔ spec's BFS extraction; `Board#eligible_board_group` (Task 2) ↔ spec's "reuse existing eligible group" rule; `Boards::BoardGroupCreator` (Task 3) ↔ spec's creation/limit/reuse behavior; endpoint (Task 4) ↔ spec's auth/limit/response-shape requirements. Frontend handoff is explicitly out of scope for this plan (delivered separately).
- **Type consistency:** `Boards::LinkedBoardsFinder.new(root_board).call` used identically in Task 1's `SetGraphBuilder` delegation and Task 3's creator. `Board#eligible_board_group` used identically in Task 2's own spec, Task 3's service, and Task 4's controller (to decide 200 vs 201). `Boards::BoardGroupCreator::LimitReached` raised in Task 3, rescued in Task 4 — names match.
- **No placeholders:** every step has runnable code and an exact command to verify it.
