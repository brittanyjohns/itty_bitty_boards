# Publish Cascade for Board Builder Sets — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publishing or unpublishing a Board Builder root board cascades to every board in its builder set, behind a confirmation prompt, so a published set's folder tiles don't 404 for public visitors.

**Architecture:** A new read-plus-apply service `Boards::PublishCascade` mirrors the existing `Boards::UsageCheck`. `Api::BoardsController#update` gains a guard that returns 409 `publish_cascade_confirmation_required` before writing anything, unless `confirm=true` — the exact warn-then-confirm protocol the board-delete flow already uses. The frontend catches that 409 in `updateBoard`, shows the existing `ConfirmAlert`, and resends with `confirm: true`.

**Tech Stack:** Rails 8 + RSpec + FactoryBot (backend); React + Ionic + Vitest (frontend).

## Global Constraints

- **Brand name is `SpeakAnyWay`** — one word, S/A/W capitalized. Never "SAW" or "Speak Anyway".
- **UI copy says "communicator"**, backend says `child_account`. Say *nonspeaking*, never *nonverbal*.
- **HTTP error semantics:** 409 = conflict requiring confirmation. Never leak internals in API errors.
- **Never commit to `main`.** All work happens on branch `feat/publish-cascade-builder-set` in the worktrees listed below.
- **Backend worktree:** `/Users/brittanyjohns/Projects/speakanyway/itty_bitty_boards/.claude/worktrees/publish-cascade`
- **Frontend worktree:** `/Users/brittanyjohns/Projects/speakanyway/itty-bitty-frontend/.claude/worktrees/publish-cascade`
- **Do not install new gems or npm packages.**
- Run backend tests with `bundle exec rspec <path>` from the backend worktree root.
- Run frontend tests with `npx vitest run <path>` from the frontend worktree root.

## File Structure

**Backend** (`itty_bitty_boards`)

| File | Responsibility |
|---|---|
| `app/services/boards/publish_cascade.rb` | **Create.** Decides whether a cascade is needed, summarizes what it will affect, applies it. |
| `app/controllers/api/boards_controller.rb` | **Modify.** Fix the `published` assignment bug (line ~451); add the 409 guard and the confirmed cascade to `#update`. |
| `spec/services/boards/publish_cascade_spec.rb` | **Create.** Unit spec for the service. |
| `spec/requests/api/boards_publish_cascade_spec.rb` | **Create.** Request spec for the 409 → confirm → cascade flow. |
| `.claude-notes/boards-and-teams.md` | **Modify.** Document the publish-cascade invariant. |
| `.claude-notes/board-builder.md` | **Modify.** Pointer to the above. |
| `CHANGELOG.md` | **Modify.** User-facing entry. |

**Frontend** (`itty-bitty-frontend`)

| File | Responsibility |
|---|---|
| `src/data/boards.ts` | **Modify.** Add `PublishCascadeError` + `PublishCascadeSummary`; make `updateBoard` detect the 409 and accept a `confirm` option. |
| `src/components/utils/publishCascade.ts` | **Create.** Turns the 409 payload into dialog copy. |
| `src/components/utils/publishCascade.test.ts` | **Create.** Unit test for the copy helper. |
| `src/data/boards.publishCascade.test.ts` | **Create.** Unit test that `updateBoard` throws on the 409 and passes `confirm`. |
| `src/components/boards/BoardForm.tsx` | **Modify.** Catch the error, open `ConfirmAlert`, resend with confirm. |
| `CHANGELOG.md` | **Modify.** User-facing entry. |

**Note on frontend test scope:** there is no component-test harness for `BoardForm` (it depends on Ionic + several contexts, and no existing `*.test.tsx` covers a form of this size). Frontend automated tests therefore cover the two pure units — the copy helper and the `updateBoard` 409 contract. Task 8 includes a manual verification script for the wiring itself.

---

## Task 1: Make `published: false` actually persist

`Api::BoardsController#update` currently assigns with
`@board.published = board_params["published"] if board_params["published"].present?`.
In Ruby `false.present?` is `false`, so **unpublishing is silently dropped today** — the
request 200s and the board stays published. The unpublish half of this feature cannot
work until this is fixed. The `predefined` line directly above already uses the correct
`.key?` guard; this makes `published` match it.

**Files:**
- Modify: `app/controllers/api/boards_controller.rb:451`
- Test: `spec/requests/api/boards_publish_cascade_spec.rb` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `PUT /api/boards/:id` with `board: { published: false }` now persists `false`. Tasks 2–3 depend on this.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/api/boards_publish_cascade_spec.rb`:

```ruby
require "rails_helper"

# Publish cascade: publishing or unpublishing a Board Builder root cascades to
# every member board of its builder BoardGroup, behind a 409 warn+confirm.
RSpec.describe "API::Boards publish cascade", type: :request do
  let(:admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }

  def update_board(target, as:, params:)
    put "/api/boards/#{target.id}", params: params, headers: auth_headers(as)
  end

  describe "unpublishing a plain board" do
    let(:board) { create(:board, user: admin, published: true) }

    it "persists published=false" do
      update_board(board, as: admin, params: { board: { published: false } })
      expect(response).to have_http_status(:ok)
      expect(board.reload.published).to be false
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec rspec spec/requests/api/boards_publish_cascade_spec.rb -e "persists published=false"
```

Expected: FAIL — `expected false, got true`. The `.present?` guard dropped the assignment.

- [ ] **Step 3: Fix the guard**

In `app/controllers/api/boards_controller.rb`, replace this line:

```ruby
      @board.published = board_params["published"] if board_params["published"].present?
```

with:

```ruby
      # `.key?`, not `.present?` — `false.present?` is false, so a `.present?`
      # guard silently drops `published: false` and makes unpublishing a no-op.
      # Matches the `predefined` guard above: a missing key leaves the saved
      # value untouched, an explicit false unpublishes.
      @board.published = board_params["published"] if board_params.key?("published")
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bundle exec rspec spec/requests/api/boards_publish_cascade_spec.rb
```

Expected: PASS.

- [ ] **Step 5: Check for regressions in the existing board specs**

```bash
bundle exec rspec spec/requests/api/boards_spec.rb spec/requests/api/board_read_only_spec.rb
```

Expected: all PASS. If a spec now fails because it relied on `published: false` being ignored, that spec was encoding the bug — fix the spec, and note it in the commit body.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/api/boards_controller.rb spec/requests/api/boards_publish_cascade_spec.rb
git commit -m "fix(boards): let published=false actually unpublish a board

board_params[\"published\"].present? is false for false, so unpublishing was
silently dropped. Use .key?, matching the predefined guard above it."
```

---

## Task 2: `Boards::PublishCascade` service

**Files:**
- Create: `app/services/boards/publish_cascade.rb`
- Test: `spec/services/boards/publish_cascade_spec.rb`

**Interfaces:**
- Consumes: `Board#builder_root?` (`app/models/board.rb:230`), `Board#builder_board_group` (`app/models/board.rb:237`), which returns a `BoardGroup` with `builder: true, root_board_id: <board>.id` whose members come from `board_group_boards`.
- Produces, used by Task 3:
  - `Boards::PublishCascade.new(board)`
  - `#needed?(published:) -> Boolean`
  - `#summary(published:) -> Hash` with keys `:action`, `:board_group`, `:affected`
  - `#apply!(published:) -> Integer` (count of member boards written)

- [ ] **Step 1: Write the failing test**

Create `spec/services/boards/publish_cascade_spec.rb`:

```ruby
require "rails_helper"

# Boards::PublishCascade decides whether publishing/unpublishing a Board
# Builder root needs to cascade to its set, and applies it. Members that
# already match the target don't count — re-saving a synced set never prompts.
RSpec.describe Boards::PublishCascade do
  let(:user) { create(:user) }

  # A builder root plus a builder BoardGroup owning `member_count` sub-boards.
  def build_builder_set(published: false, member_count: 2, members_published: false)
    root = create(:board, user: user, name: "Home", published: published,
                          settings: { "builder_root" => true })
    group = BoardGroup.create!(user: user, name: "Milo's Set", builder: true,
                               root_board_id: root.id)
    group.board_group_boards.create!(board: root)
    members = Array.new(member_count) do |i|
      m = create(:board, user: user, name: "Page #{i + 1}", published: members_published,
                         settings: { "builder_child" => true })
      group.board_group_boards.create!(board: m)
      m
    end
    [root, group, members]
  end

  describe "#needed?" do
    it "is true when publishing a root whose members are unpublished" do
      root, _group, _members = build_builder_set
      expect(described_class.new(root).needed?(published: true)).to be true
    end

    it "is false when every member already matches the target" do
      root, _group, _members = build_builder_set(members_published: true)
      expect(described_class.new(root).needed?(published: true)).to be false
    end

    it "is false for a board that is not a builder root" do
      plain = create(:board, user: user)
      expect(described_class.new(plain).needed?(published: true)).to be false
    end

    it "is false for a builder root with no member boards besides itself" do
      root = create(:board, user: user, settings: { "builder_root" => true })
      group = BoardGroup.create!(user: user, name: "Empty", builder: true, root_board_id: root.id)
      group.board_group_boards.create!(board: root)
      expect(described_class.new(root).needed?(published: true)).to be false
    end

    it "is true when unpublishing a root whose members are published" do
      root, _group, _members = build_builder_set(published: true, members_published: true)
      expect(described_class.new(root).needed?(published: false)).to be true
    end
  end

  describe "#summary" do
    it "reports the action, group, and exact affected count" do
      root, group, _members = build_builder_set(member_count: 3)
      summary = described_class.new(root).summary(published: true)

      expect(summary[:action]).to eq("publish")
      expect(summary[:board_group]).to eq({ id: group.id, name: "Milo's Set" })
      expect(summary[:affected][:count]).to eq(3)
      expect(summary[:affected][:names]).to contain_exactly("Page 1", "Page 2", "Page 3")
    end

    it "says unpublish when the target is false" do
      root, _group, _members = build_builder_set(published: true, members_published: true)
      expect(described_class.new(root).summary(published: false)[:action]).to eq("unpublish")
    end

    it "caps the name list but keeps the count exact" do
      root, _group, _members = build_builder_set(member_count: 14)
      summary = described_class.new(root).summary(published: true)

      expect(summary[:affected][:count]).to eq(14)
      expect(summary[:affected][:names].size).to eq(described_class::NAME_SAMPLE_LIMIT)
    end
  end

  describe "#apply!" do
    it "publishes every member and returns the count written" do
      root, _group, members = build_builder_set(member_count: 3)
      count = described_class.new(root).apply!(published: true)

      expect(count).to eq(3)
      expect(members.map { |m| m.reload.published }).to all(be true)
    end

    it "does not write the root board itself" do
      root, _group, _members = build_builder_set
      described_class.new(root).apply!(published: true)
      expect(root.reload.published).to be false
    end

    it "unpublishes every member" do
      root, _group, members = build_builder_set(published: true, members_published: true)
      described_class.new(root).apply!(published: false)
      expect(members.map { |m| m.reload.published }).to all(be false)
    end

    it "touches updated_at on the members it writes" do
      root, _group, members = build_builder_set
      before = members.first.updated_at
      travel_to(1.hour.from_now) { described_class.new(root).apply!(published: true) }
      expect(members.first.reload.updated_at).to be > before
    end

    it "is a no-op returning 0 for a non-builder board" do
      plain = create(:board, user: user)
      expect(described_class.new(plain).apply!(published: true)).to eq(0)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bundle exec rspec spec/services/boards/publish_cascade_spec.rb
```

Expected: FAIL with `uninitialized constant Boards::PublishCascade`.

- [ ] **Step 3: Write the service**

Create `app/services/boards/publish_cascade.rb`:

```ruby
module Boards
  # Publishing a Board Builder root without its set leaves a broken public
  # page: Board#viewable_by? gates each board on its own `published` flag, so
  # a visitor tapping a folder tile on a published root hits the sub-page's
  # 404. Unpublishing only the root leaks the reverse — every sub-page stays
  # reachable by its own /pb/<slug>.
  #
  # This cascades `published` across the boards owned by the root's builder
  # BoardGroup — the SAME set Boards::UsageCheck#builder_group cascades on
  # delete, so a built set publishes, unpublishes, and deletes as one unit.
  # Deliberately NOT PredictiveLinkSet: hand-linked folder tiles outside the
  # builder set are not owned by the root and are not ours to flip.
  class PublishCascade
    # Counts in the summary are exact; name lists are sampled so a large set
    # can't blow up the 409 payload. Mirrors UsageCheck::NAME_SAMPLE_LIMIT.
    NAME_SAMPLE_LIMIT = 10

    def initialize(board)
      @board = board
    end

    # Only boards that would actually change count, so re-saving an
    # already-synced set never prompts the user.
    def needed?(published:)
      member_boards_to_change(published).exists?
    end

    def summary(published:)
      group = builder_group
      scope = member_boards_to_change(published)

      {
        action: published ? "publish" : "unpublish",
        board_group: group ? { id: group.id, name: group.name } : nil,
        affected: {
          count: scope.count,
          names: scope.limit(NAME_SAMPLE_LIMIT).pluck(:name),
        },
      }
    end

    # Flips the members only — the root is saved by the caller through the
    # normal update path. update_all skips callbacks on purpose: a built set
    # can be dozens of boards and only one boolean column changes. It also
    # skips timestamps, so updated_at is set explicitly.
    def apply!(published:)
      ids = member_boards_to_change(published).pluck(:id)
      return 0 if ids.empty?

      Board.where(id: ids).update_all(published: published, updated_at: Time.current)
      ids.size
    end

    # The builder BoardGroup owning this root's built tree, or nil when this
    # board isn't a Board Builder root.
    def builder_group
      return @builder_group if defined?(@builder_group)
      @builder_group = board.builder_board_group
    end

    private

    attr_reader :board

    # Member boards whose published flag differs from the target. Excludes the
    # root itself — it's a member of its own group, but the caller saves it.
    def member_boards_to_change(published)
      group = builder_group
      return Board.none unless group

      group.boards.where.not(id: board.id).where.not(published: published)
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bundle exec rspec spec/services/boards/publish_cascade_spec.rb
```

Expected: all PASS. If the `updated_at` example fails because `travel_to` isn't available, confirm `config.include ActiveSupport::Testing::TimeHelpers` is in `spec/rails_helper.rb`; if it isn't, add it.

- [ ] **Step 5: Commit**

```bash
git add app/services/boards/publish_cascade.rb spec/services/boards/publish_cascade_spec.rb
git commit -m "feat(boards): add Boards::PublishCascade service

Decides whether publishing/unpublishing a Board Builder root needs to
cascade to its set, summarizes what it affects, and applies it. Cascades
over builder BoardGroup membership - the same set UsageCheck cascades on
delete - so a built set publishes and deletes as one unit."
```

---

## Task 3: Controller 409 guard and confirmed cascade

**Files:**
- Modify: `app/controllers/api/boards_controller.rb` — `#update`, starting at line 412
- Test: `spec/requests/api/boards_publish_cascade_spec.rb` (extend the file from Task 1)

**Interfaces:**
- Consumes: `Boards::PublishCascade#needed?`, `#summary`, `#apply!` from Task 2; the fixed `published` assignment from Task 1.
- Produces: `PUT /api/boards/:id` returns 409 `publish_cascade_confirmation_required` with a `cascade` key; `?confirm=true` performs the cascade.

- [ ] **Step 1: Write the failing tests**

Replace the whole body of `spec/requests/api/boards_publish_cascade_spec.rb` with this (it keeps the Task 1 example and adds the cascade cases):

```ruby
require "rails_helper"

# Publish cascade: publishing or unpublishing a Board Builder root cascades to
# every member board of its builder BoardGroup, behind a 409 warn+confirm that
# mirrors the board-delete flow. `published` is admin-only server-side, so the
# cascade is only ever reachable by admins.
RSpec.describe "API::Boards publish cascade", type: :request do
  let(:admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }
  let(:member_user) { create(:user) }

  def update_board(target, as:, params:)
    put "/api/boards/#{target.id}", params: params, headers: auth_headers(as)
  end

  # A builder root plus a builder BoardGroup owning two sub-boards.
  def build_builder_set(owner:, published: false, members_published: false)
    root = create(:board, user: owner, name: "Home", published: published,
                          settings: { "builder_root" => true })
    group = BoardGroup.create!(user: owner, name: "Milo's Set", builder: true,
                               root_board_id: root.id)
    group.board_group_boards.create!(board: root)
    members = ["Food", "Feelings"].map do |name|
      m = create(:board, user: owner, name: name, published: members_published,
                         settings: { "builder_child" => true })
      group.board_group_boards.create!(board: m)
      m
    end
    [root, members]
  end

  describe "unpublishing a plain board" do
    let(:board) { create(:board, user: admin, published: true) }

    it "persists published=false" do
      update_board(board, as: admin, params: { board: { published: false } })
      expect(response).to have_http_status(:ok)
      expect(board.reload.published).to be false
    end
  end

  describe "publishing a builder root with unpublished members" do
    it "returns 409 with the affected set and writes nothing" do
      root, members = build_builder_set(owner: admin)

      update_board(root, as: admin, params: { board: { published: true } })

      expect(response).to have_http_status(:conflict)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("publish_cascade_confirmation_required")
      expect(body["cascade"]["action"]).to eq("publish")
      expect(body["cascade"]["board_group"]["name"]).to eq("Milo's Set")
      expect(body["cascade"]["affected"]["count"]).to eq(2)
      expect(body["cascade"]["affected"]["names"]).to contain_exactly("Food", "Feelings")

      expect(root.reload.published).to be false
      expect(members.map { |m| m.reload.published }).to all(be false)
    end

    it "leaves other attributes in the same payload unwritten" do
      root, _members = build_builder_set(owner: admin)

      update_board(root, as: admin, params: { board: { published: true, name: "Renamed" } })

      expect(response).to have_http_status(:conflict)
      expect(root.reload.name).to eq("Home")
    end

    it "publishes the root and every member with confirm=true" do
      root, members = build_builder_set(owner: admin)

      update_board(root, as: admin, params: { board: { published: true }, confirm: "true" })

      expect(response).to have_http_status(:ok)
      expect(root.reload.published).to be true
      expect(members.map { |m| m.reload.published }).to all(be true)
    end
  end

  describe "unpublishing a published builder root" do
    it "returns 409 with the unpublish action" do
      root, _members = build_builder_set(owner: admin, published: true, members_published: true)

      update_board(root, as: admin, params: { board: { published: false } })

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["cascade"]["action"]).to eq("unpublish")
    end

    it "unpublishes the root and every member with confirm=true" do
      root, members = build_builder_set(owner: admin, published: true, members_published: true)

      update_board(root, as: admin, params: { board: { published: false }, confirm: "true" })

      expect(response).to have_http_status(:ok)
      expect(root.reload.published).to be false
      expect(members.map { |m| m.reload.published }).to all(be false)
    end
  end

  describe "when no cascade is needed" do
    it "does not prompt when members already match the target" do
      root, _members = build_builder_set(owner: admin, members_published: true)

      update_board(root, as: admin, params: { board: { published: true } })

      expect(response).to have_http_status(:ok)
      expect(root.reload.published).to be true
    end

    it "does not prompt for a board that is not a builder root" do
      plain = create(:board, user: admin, name: "Plain")
      other = create(:board, user: admin, published: false)

      update_board(plain, as: admin, params: { board: { published: true } })

      expect(response).to have_http_status(:ok)
      expect(plain.reload.published).to be true
      expect(other.reload.published).to be false
    end

    it "does not prompt when published is absent from the payload" do
      root, _members = build_builder_set(owner: admin)

      update_board(root, as: admin, params: { board: { name: "Renamed" } })

      expect(response).to have_http_status(:ok)
      expect(root.reload.name).to eq("Renamed")
    end
  end

  describe "non-admin" do
    it "cannot trigger the cascade because published is stripped" do
      root, members = build_builder_set(owner: member_user)

      update_board(root, as: member_user, params: { board: { published: true } })

      expect(response).to have_http_status(:ok)
      expect(root.reload.published).to be false
      expect(members.map { |m| m.reload.published }).to all(be false)
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bundle exec rspec spec/requests/api/boards_publish_cascade_spec.rb
```

Expected: the "unpublishing a plain board" example PASSES (Task 1). Every cascade example FAILS — 409 examples get 200 because no guard exists yet.

- [ ] **Step 3: Add the guard to `#update`**

In `app/controllers/api/boards_controller.rb`, inside `def update`, insert the guard immediately after the authorization check and **before** the `if params["image_ids_to_remove"].present?` branch — i.e. between these two existing lines:

```ruby
    unless current_user.can_edit?(@board)
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end
```

and

```ruby
    if params["image_ids_to_remove"].present?
```

Insert:

```ruby
    # Warn+confirm before cascading publish across a Board Builder set, mirroring
    # the delete flow. This runs BEFORE any attribute is assigned, so a declined
    # cascade writes nothing at all — the client re-sends the identical payload
    # with confirm=true. `published` is stripped from board_params for
    # non-admins, so this is unreachable for them.
    if board_params.key?("published")
      target_published = ActiveModel::Type::Boolean.new.cast(board_params["published"])
      if target_published != @board.published
        cascade = Boards::PublishCascade.new(@board)
        if cascade.needed?(published: target_published) && params[:confirm].to_s != "true"
          render json: {
                   error: "publish_cascade_confirmation_required",
                   message: "\"#{@board.name}\" is the home of a board set — this change applies to every page in the set.",
                   board: { id: @board.id, name: @board.name },
                   cascade: cascade.summary(published: target_published),
                 }, status: :conflict
          return
        end
        @publish_cascade = cascade
        @publish_cascade_target = target_published
      end
    end
```

- [ ] **Step 4: Apply the cascade in the same transaction as the root save**

Still in `#update`, the success path is a `respond_to` block whose condition is the
save itself (`app/controllers/api/boards_controller.rb:503-504`):

```ruby
      respond_to do |format|
        if @board.save
          if params[:layout].present?
```

The save has to move out of the condition so it can share a transaction with the
cascade — otherwise the root commits before the members flip, and a cascade failure
leaves the set half-published. Replace those three lines with:

```ruby
      # The root's save and the set cascade share one transaction: a failed
      # cascade must not leave the root published with its members behind.
      saved = false
      ActiveRecord::Base.transaction do
        saved = @board.save
        raise ActiveRecord::Rollback unless saved
        @publish_cascade&.apply!(published: @publish_cascade_target)
      end

      respond_to do |format|
        if saved
          if params[:layout].present?
```

Everything inside the block — the layout handling, `broadcast_board_update!`, both
`format.json` branches, and the closing `end`s — is unchanged.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bundle exec rspec spec/requests/api/boards_publish_cascade_spec.rb
```

Expected: all PASS.

- [ ] **Step 6: Check for regressions across the board request specs**

```bash
bundle exec rspec spec/requests/api/boards_spec.rb spec/requests/api/boards_destroy_spec.rb spec/requests/api/board_read_only_spec.rb spec/requests/api/board_groups_spec.rb spec/services/boards/
```

Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/api/boards_controller.rb spec/requests/api/boards_publish_cascade_spec.rb
git commit -m "feat(boards): cascade publish/unpublish across a Board Builder set

PUT /boards/:id now returns 409 publish_cascade_confirmation_required when
toggling published on a builder root would leave its set out of sync. The
guard runs before any attribute is assigned, so a declined cascade writes
nothing; re-sending with confirm=true publishes the root and every member
in one transaction."
```

---

## Task 4: Backend documentation

**Files:**
- Modify: `.claude-notes/boards-and-teams.md`
- Modify: `.claude-notes/board-builder.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the behavior built in Tasks 1–3.
- Produces: nothing code-facing.

- [ ] **Step 1: Document the invariant in `boards-and-teams.md`**

Find the existing "Board deletion safety (warn + confirm)" section and add this immediately after it:

```markdown
### Publish cascade (warn + confirm)

A Board Builder set publishes and unpublishes as a **unit**. `Board#viewable_by?`
gates each board on its own `published` flag, so publishing only the root leaves
folder tiles 404ing for public visitors, and unpublishing only the root leaves
every sub-page reachable by its own `/pb/<slug>`.

`PUT /api/boards/:id` returns **409 `publish_cascade_confirmation_required`**
when `published` would change on a builder root whose set members don't already
match. The body carries `cascade: { action, board_group, affected: { count, names } }`.
Re-send the identical payload with `confirm=true` to apply it; the root's save and
`Boards::PublishCascade#apply!` run in one transaction.

The guard runs **before any attribute is assigned**, so a declined cascade writes
nothing — other fields in the same payload are neither applied nor lost.

The cascade set is the root's builder `BoardGroup` membership — the same set
`Boards::UsageCheck#builder_group` cascades on delete. Hand-linked folder-tile
descendants (`board_images.predictive_board_id`) outside the builder set are
deliberately **not** included: they aren't owned by the root.

`published` is admin-only (`board_params` strips it for non-admins), so the
cascade is unreachable for regular users.
```

- [ ] **Step 2: Add the pointer in `board-builder.md`**

Add this line to the end of the document:

```markdown
- **Publishing:** a built set publishes and unpublishes as a unit, behind a 409
  warn+confirm. See "Publish cascade (warn + confirm)" in
  `.claude-notes/boards-and-teams.md`.
```

- [ ] **Step 3: Add the CHANGELOG entry**

Add under the topmost unreleased heading in `CHANGELOG.md` (create an `## Unreleased` heading at the top if none exists):

```markdown
### Fixed
- Publishing a Board Builder board set now publishes every page in the set, so
  public visitors no longer hit a dead end when tapping a folder button.
  Unpublishing removes the whole set from public view. Both ask for confirmation
  first.
- Unpublishing a board works again — `published: false` was being silently
  dropped by the update endpoint.
```

- [ ] **Step 4: Commit**

```bash
git add -f .claude-notes/boards-and-teams.md .claude-notes/board-builder.md
git add CHANGELOG.md
git commit -m "docs(boards): document the publish cascade invariant"
```

Note the `-f` — `.claude-notes/` is gitignored and durable subsystem docs are force-added.

---

## Task 5: Frontend — typed 409 error and `confirm` option

Work from the **frontend worktree** for Tasks 5–8.

**Files:**
- Modify: `src/data/boards.ts` — `updateBoard` (line ~518) and the error classes near line ~630
- Test: `src/data/boards.publishCascade.test.ts` (create)

**Interfaces:**
- Consumes: the 409 body shape from Task 3 — `{ error: "publish_cascade_confirmation_required", message, board: { id, name }, cascade: { action, board_group: { id, name }, affected: { count, names } } }`.
- Produces, used by Tasks 6–7:
  - `export interface PublishCascadeSummary { action: "publish" | "unpublish"; board_group: { id: number; name: string } | null; affected: { count: number; names: string[] } }`
  - `export class PublishCascadeError extends Error { cascade: PublishCascadeSummary | null; boardName: string }`
  - `updateBoard(board, updatedLayout?, screenSize?, xMargin?, yMargin?, duplicateWords?, opts?: { confirm?: boolean })`

- [ ] **Step 1: Write the failing test**

Create `src/data/boards.publishCascade.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { updateBoard, PublishCascadeError } from "./boards";

const CASCADE_BODY = {
  error: "publish_cascade_confirmation_required",
  message: "\"Home\" is the home of a board set.",
  board: { id: 1, name: "Home" },
  cascade: {
    action: "publish",
    board_group: { id: 9, name: "Milo's Set" },
    affected: { count: 12, names: ["Food", "Feelings"] },
  },
};

const board: any = { id: 1, name: "Home", published: true, settings: {} };

describe("updateBoard publish cascade", () => {
  beforeEach(() => {
    vi.stubGlobal("localStorage", {
      getItem: () => null,
      setItem: () => {},
      removeItem: () => {},
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("throws PublishCascadeError with the cascade payload on a 409", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        status: 409,
        ok: false,
        json: async () => CASCADE_BODY,
      }),
    );

    await expect(updateBoard(board)).rejects.toBeInstanceOf(PublishCascadeError);

    try {
      await updateBoard(board);
    } catch (e) {
      const err = e as PublishCascadeError;
      expect(err.cascade?.action).toBe("publish");
      expect(err.cascade?.affected.count).toBe(12);
      expect(err.boardName).toBe("Home");
    }
  });

  it("sends confirm=true in the body when the option is set", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      status: 200,
      ok: true,
      json: async () => ({ id: 1 }),
    });
    vi.stubGlobal("fetch", fetchMock);

    await updateBoard(board, undefined, undefined, undefined, undefined, false, {
      confirm: true,
    });

    const body = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(body.confirm).toBe(true);
  });

  it("does not send confirm when the option is absent", async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      status: 200,
      ok: true,
      json: async () => ({ id: 1 }),
    });
    vi.stubGlobal("fetch", fetchMock);

    await updateBoard(board);

    const body = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(body.confirm).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
npx vitest run src/data/boards.publishCascade.test.ts
```

Expected: FAIL — `PublishCascadeError` is not exported.

- [ ] **Step 3: Add the types and the error class**

In `src/data/boards.ts`, add immediately after the existing `BoardInUseError` class:

```ts
// The 409 publish_cascade_confirmation_required payload: publishing or
// unpublishing a Board Builder root applies to every page in its set.
export interface PublishCascadeSummary {
  action: "publish" | "unpublish";
  board_group: { id: number; name: string } | null;
  affected: { count: number; names: string[] };
}

// Thrown when PUT /boards/:id returns 409 publish_cascade_confirmation_required.
// Nothing was written. Retry the identical payload with { confirm: true }.
export class PublishCascadeError extends Error {
  cascade: PublishCascadeSummary | null;
  boardName: string;
  constructor(body: any) {
    super(body?.message || "publish_cascade_confirmation_required");
    this.name = "PublishCascadeError";
    this.cascade = body?.cascade ?? null;
    this.boardName = body?.board?.name ?? "";
  }
}
```

- [ ] **Step 4: Make `updateBoard` async, detect the 409, and accept `confirm`**

Replace the `updateBoard` signature line:

```ts
  duplicateWords?: boolean,
) => {
```

with:

```ts
  duplicateWords?: boolean,
  // Re-send after the user confirms a publish cascade (409
  // publish_cascade_confirmation_required). Only ever set by that retry.
  opts?: { confirm?: boolean },
) => {
```

Then replace the whole `const updatedBoard = fetch(...)` block through `return updatedBoard;` with:

```ts
  const response = await fetch(`${BASE_URL}boards/${board.id}`, {
    method: "PUT",
    headers: signedInHeaders(),
    body: JSON.stringify({
      board: payload,
      word_list: board.word_list,
      duplicate_words: duplicateWords,
      layout: updatedLayout,
      screen_size: screenSize,
      image_ids_to_remove: board.image_ids_to_remove,
      xMargin: xMargin,
      yMargin: yMargin,
      ...(opts?.confirm ? { confirm: true } : {}),
    }),
  });

  if (response.status === 409) {
    let body: any = null;
    try {
      body = await response.json();
    } catch {
      /* no body */
    }
    if (body?.error === "publish_cascade_confirmation_required") {
      throw new PublishCascadeError(body);
    }
    return body;
  }

  return await response.json();
```

Change the arrow function to `async`: the declaration becomes

```ts
export const updateBoard = async (
```

Note: this drops the old `.catch((error) => console.error(...))`, which swallowed every network failure and returned `undefined`. Callers now see rejections. Task 7 handles that in `BoardForm`; other callers pass layout-only saves that never set `published`, so they cannot hit the 409.

- [ ] **Step 5: Run the test to verify it passes**

```bash
npx vitest run src/data/boards.publishCascade.test.ts
```

Expected: all PASS.

- [ ] **Step 6: Typecheck and check for callers broken by the async change**

```bash
npx tsc --noEmit
```

Expected: no errors. If a caller assigned `updateBoard(...)` without `await` and used the result synchronously, add the `await`.

- [ ] **Step 7: Commit**

```bash
git add src/data/boards.ts src/data/boards.publishCascade.test.ts
git commit -m "feat(boards): surface the publish-cascade 409 from updateBoard

Adds PublishCascadeError + PublishCascadeSummary and a confirm option so
the caller can re-send after the user approves the cascade. updateBoard is
now async and no longer swallows failures into console.error."
```

---

## Task 6: Frontend — confirmation copy helper

**Files:**
- Create: `src/components/utils/publishCascade.ts`
- Test: `src/components/utils/publishCascade.test.ts`

**Interfaces:**
- Consumes: `PublishCascadeError` and `PublishCascadeSummary` from Task 5.
- Produces, used by Task 7: `publishCascadeCopy(err: PublishCascadeError) -> { header: string; body: string; confirmLabel: string }`.

- [ ] **Step 1: Write the failing test**

Create `src/components/utils/publishCascade.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { publishCascadeCopy } from "./publishCascade";
import { PublishCascadeError } from "../../data/boards";

const err = (action: "publish" | "unpublish", count: number) =>
  new PublishCascadeError({
    message: "cascade",
    board: { id: 1, name: "Home" },
    cascade: {
      action,
      board_group: { id: 9, name: "Milo's Set" },
      affected: { count, names: ["Food", "Feelings"] },
    },
  });

describe("publishCascadeCopy", () => {
  it("frames publishing as making the whole set visible", () => {
    const copy = publishCascadeCopy(err("publish", 12));
    expect(copy.header).toBe("Publish the whole set?");
    expect(copy.body).toContain("12 pages");
    expect(copy.body).toContain("publicly visible");
    expect(copy.confirmLabel).toBe("Publish set");
  });

  it("frames unpublishing as removing the whole set", () => {
    const copy = publishCascadeCopy(err("unpublish", 12));
    expect(copy.header).toBe("Unpublish the whole set?");
    expect(copy.body).toContain("12 pages");
    expect(copy.body).toContain("remove");
    expect(copy.confirmLabel).toBe("Unpublish set");
  });

  it("uses singular wording for one page", () => {
    const copy = publishCascadeCopy(err("publish", 1));
    expect(copy.body).toContain("1 page ");
    expect(copy.body).not.toContain("pages");
  });

  it("falls back to the raw message when the payload is missing", () => {
    const bare = new PublishCascadeError({ message: "Something changed." });
    expect(publishCascadeCopy(bare).body).toBe("Something changed.");
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
npx vitest run src/components/utils/publishCascade.test.ts
```

Expected: FAIL — cannot resolve `./publishCascade`.

- [ ] **Step 3: Write the helper**

Create `src/components/utils/publishCascade.ts`:

```ts
import { PublishCascadeError } from "../../data/boards";

// Turn the backend's publish_cascade_confirmation_required payload into copy
// for the confirm dialog. Publishing is framed as what makes the public page
// work (unpublished pages 404 when a visitor taps a folder button);
// unpublishing is framed as closing the direct-link leak.
export const publishCascadeCopy = (
  err: PublishCascadeError,
): { header: string; body: string; confirmLabel: string } => {
  const cascade = err.cascade;

  if (!cascade) {
    return { header: "Apply to the whole set?", body: err.message, confirmLabel: "Continue" };
  }

  const { count } = cascade.affected;
  const pages = count === 1 ? "1 page " : `${count} pages `;

  if (cascade.action === "unpublish") {
    return {
      header: "Unpublish the whole set?",
      body: `This board set has ${pages}beyond this one. Unpublishing will also remove ${count === 1 ? "it" : "them"} from public view.`,
      confirmLabel: "Unpublish set",
    };
  }

  return {
    header: "Publish the whole set?",
    body: `This board set has ${pages}beyond this one. Publishing will also make ${count === 1 ? "it" : "them"} publicly visible, so folder buttons work for everyone.`,
    confirmLabel: "Publish set",
  };
};
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
npx vitest run src/components/utils/publishCascade.test.ts
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/components/utils/publishCascade.ts src/components/utils/publishCascade.test.ts
git commit -m "feat(boards): add publish-cascade confirm dialog copy helper"
```

---

## Task 7: Frontend — wire the confirm dialog into `BoardForm`

**Files:**
- Modify: `src/components/boards/BoardForm.tsx` — `handleSubmit` (line ~428) and the JSX render tail

**Interfaces:**
- Consumes: `updateBoard(..., opts)` and `PublishCascadeError` (Task 5), `publishCascadeCopy` (Task 6), the existing `ConfirmAlert` at `src/components/utils/ConfirmAlert.tsx`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the imports**

At the top of `src/components/boards/BoardForm.tsx`, add to the existing `src/data/boards` import the two new names, and add the two new imports:

```tsx
import { PublishCascadeError } from "../../data/boards";
import { publishCascadeCopy } from "../utils/publishCascade";
import ConfirmAlert from "../utils/ConfirmAlert";
```

If `ConfirmAlert` is already imported in this file, don't duplicate it.

- [ ] **Step 2: Add the pending-cascade state**

Next to the other `useState` declarations near the top of the component, add:

```tsx
  // Set when a save was rejected with 409 publish_cascade_confirmation_required.
  // Holds the error so the dialog can render its copy and the retry can re-send.
  const [pendingCascade, setPendingCascade] = useState<PublishCascadeError | null>(null);
```

- [ ] **Step 3: Extract the save so it can be retried with confirm**

In `handleSubmit`, replace this block:

```tsx
    const savedBoard = await updateBoard(
      toSave,
      updatedLayout,
      currentScreenSize,
      xMargin,
      yMargin,
    );
    pushBoardUp(savedBoard);

    setShowLoading(false);
    setToastMessage("Board saved successfully");
    setIsToastOpen(true);
  };
```

with:

```tsx
    await saveBoard(toSave, { confirm: false });
  };

  // The single save path. A publish cascade comes back as a 409 with nothing
  // written; we stash it, show the confirm dialog, and re-send the identical
  // payload with confirm: true when the user approves.
  const saveBoard = async (
    toSave: any,
    { confirm }: { confirm: boolean },
  ) => {
    try {
      const savedBoard = await updateBoard(
        toSave,
        updatedLayout,
        currentScreenSize,
        xMargin,
        yMargin,
        false,
        confirm ? { confirm: true } : undefined,
      );
      pushBoardUp(savedBoard);
      setPendingCascade(null);
      setShowLoading(false);
      setToastMessage("Board saved successfully");
      setIsToastOpen(true);
    } catch (e) {
      setShowLoading(false);
      if (e instanceof PublishCascadeError) {
        // Nothing was saved — hold the payload so the retry re-sends it intact.
        setPendingCascade(e);
        setPendingCascadePayload(toSave);
        return;
      }
      setToastMessage("Could not save board. Please try again.");
      setIsToastOpen(true);
    }
  };
```

- [ ] **Step 4: Add the held payload state**

Alongside `pendingCascade` from Step 2, add:

```tsx
  // The exact payload the 409 rejected, so the confirmed retry re-sends it
  // unchanged rather than rebuilding it from possibly-restaled state.
  const [pendingCascadePayload, setPendingCascadePayload] = useState<any>(null);
```

- [ ] **Step 5: Render the dialog**

In the component's returned JSX, add this next to the other overlays (near the existing loading/toast elements at the end of the render):

```tsx
      {pendingCascade && (
        <ConfirmAlert
          openAlert={Boolean(pendingCascade)}
          message={publishCascadeCopy(pendingCascade).header}
          subMessage={publishCascadeCopy(pendingCascade).body}
          confirmLabel={publishCascadeCopy(pendingCascade).confirmLabel}
          onConfirm={() => {
            const payload = pendingCascadePayload;
            setPendingCascade(null);
            setShowLoading(true);
            saveBoard(payload, { confirm: true });
          }}
          onCanceled={() => {
            setPendingCascade(null);
            setPendingCascadePayload(null);
          }}
          onDidDismiss={() => setPendingCascade(null)}
        />
      )}
```

- [ ] **Step 6: Typecheck and build**

```bash
npx tsc --noEmit && npm run build
```

Expected: both succeed.

- [ ] **Step 7: Run the full frontend test suite for regressions**

```bash
npx vitest run
```

Expected: all PASS.

- [ ] **Step 8: Manual verification**

There is no component-test harness for `BoardForm`, so verify the wiring by hand against a local backend (`bin/dev` in the backend worktree, `npm run dev` in the frontend worktree), signed in as an admin:

1. Open a Board Builder set's root board in the board editor, go to "Sharing & Publishing".
2. Toggle **Publish** on and save → the dialog reads "Publish the whole set?" with the correct page count.
3. Cancel → nothing saves; the board stays unpublished.
4. Save again and confirm → the root and every sub-page show `published: true`.
5. Open the public `/pb/<slug>` in a signed-out window and tap a folder button → the sub-page loads instead of 404ing.
6. Toggle **Publish** off and save → the dialog reads "Unpublish the whole set?"; confirming unpublishes all of them.
7. Save the root again with no publish change → no dialog appears.

- [ ] **Step 9: Commit**

```bash
git add src/components/boards/BoardForm.tsx
git commit -m "feat(boards): confirm before cascading publish across a board set

Catches the 409 from updateBoard, shows the existing ConfirmAlert with
set-aware copy, and re-sends the untouched payload with confirm: true when
the user approves."
```

---

## Task 8: Frontend CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the behavior built in Tasks 5–7.
- Produces: nothing.

- [ ] **Step 1: Add the entry**

Add under the topmost unreleased heading in `CHANGELOG.md` (create an `## Unreleased` heading at the top if none exists):

```markdown
### Fixed
- Publishing a board set now asks whether to publish every page in it, so the
  public page's folder buttons work instead of hitting a dead end. Unpublishing
  asks the same and removes the whole set from public view.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog entry for the publish cascade confirm flow"
```

---

## Task 9: File the follow-up issue

The spec explicitly puts this out of scope, but it must not be lost: `BoardForm.tsx`
shows the publish toggle, public URL, and QR code to every signed-in user, while
`board_params` deletes `:published` for non-admins. A non-admin toggling Publish
gets a success toast and no publish.

**Files:** none.

- [ ] **Step 1: Open the issue**

```bash
gh issue create --repo brittanyjohns/itty-bitty-frontend \
  --title "Publish toggle is shown to non-admins but the backend discards it" \
  --body "BoardForm.tsx renders the \"Publish this board\" toggle, the public URL, and the QR code for every signed-in user. The backend strips \`:published\` from \`board_params\` for non-admins (\`app/controllers/api/boards_controller.rb\`, the admin guard in \`board_params\`), so a non-admin toggling Publish gets a success toast and no publish.

Either admin-gate the toggle in the UI, or allow board owners to publish their own boards. This is a permissions decision, not a bug fix.

Found while building the publish cascade for Board Builder sets, which is admin-only for exactly this reason."
```

---

## Verification Before Completion

Before claiming done, run and confirm zero failures:

**Backend** (from the backend worktree):

```bash
bundle exec rspec spec/services/boards/publish_cascade_spec.rb spec/requests/api/boards_publish_cascade_spec.rb spec/requests/api/boards_spec.rb spec/requests/api/boards_destroy_spec.rb spec/requests/api/board_read_only_spec.rb spec/requests/api/board_groups_spec.rb
```

**Frontend** (from the frontend worktree):

```bash
npx vitest run && npx tsc --noEmit && npm run build
```

Then complete the Task 7 Step 8 manual checklist. Report the actual command output — do not claim passing tests without it.

## PR

Two PRs, backend first (the frontend 409 handling is inert until the backend
ships it). Both from branch `feat/publish-cascade-builder-set`.

- `brittanyjohns/itty_bitty_boards` — the cascade service, controller guard, the
  `published: false` fix, specs, and `.claude-notes` docs.
- `brittanyjohns/itty-bitty-frontend` — the typed 409, copy helper, and dialog wiring.

Cross-link them in both descriptions, and note in the frontend PR that it depends
on the backend one.
