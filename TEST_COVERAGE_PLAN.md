# Test Coverage Plan

## Current State

The project has two test frameworks running in parallel — RSpec (`spec/`) and Minitest (`test/`). The Minitest files are 100% Rails generator stubs with no actual test content. The RSpec suite has a mix of real tests and pending stubs.

### What's real (keep)

| File | Tests | Notes |
|---|---|---|
| `spec/models/board_spec.rb` | 6 | `find_or_create_images_from_word_list` — good coverage |
| `spec/models/user_spec.rb` | 5 | Validation + `invite_new_user_to_team!` |
| `spec/models/image_spec.rb` | 8 | `display_image_url` across user/admin/nil |
| `spec/models/board_group_spec.rb` | 4 | Basic associations |
| `spec/models/doc_spec.rb` | 1 | `.for_user` scope |
| `spec/controllers/api/menus_controller_spec.rb` | 3 | index/show/create |
| `spec/requests/api/board_images_rate_limit_spec.rb` | 4 | Well-written; covers daily reset + missing record |
| `spec/requests/scenarios_spec.rb` | ~7 | Standard CRUD |
| `spec/requests/prompt_templates_spec.rb` | 4 | Basic GET checks |
| `spec/factories.rb` | — | Mostly usable; a few issues (see Phase 1) |

### What's dead weight (delete)

**All 63 Minitest files in `test/`** — zero have any test content. Every file is a Rails generator stub (`# This file is currently empty` or blank class body). Keeping them creates confusion about which framework is canonical.

```
rm -rf test/
```

**RSpec stubs to delete** — pending stubs for things that don't need dedicated tests or will be covered by request specs:

- `spec/controllers/api/boards_controller_spec.rb` — entirely commented out; prefer request specs over controller specs
- `spec/helpers/api/messages_helper_spec.rb` — commented out; helpers are trivial
- `spec/helpers/api/profiles_helper_spec.rb` — check if it has content; if pending, delete
- `spec/routing/scenarios_routing_spec.rb` — routing is validated by request specs
- `spec/requests/api/webhooks_spec.rb` — empty file (0 bytes)
- `spec/requests/api/board_groups_spec.rb` — pending stub; replace with real tests (see Phase 2)
- `spec/requests/api/messages_spec.rb` — pending stub; low priority, delete for now
- `spec/requests/api/profiles_spec.rb` — pending stub; replace with real tests (see Phase 2)
- `spec/models/child_account_spec.rb` — pending stub; fill in (see Phase 3)
- All `spec/sidekiq/*` pending stubs — 7 of 9 are one-liners; fill in the 2 that matter (see Phase 4), delete the rest

---

## Plan

### Phase 1 — Foundation (do first, ~1 hour)

Nothing else works well without these.

**1a. Fix `spec/rails_helper.rb` — add auth helper and SimpleCov**

```ruby
# At the top of rails_helper.rb, before other requires:
require "simplecov"
SimpleCov.start "rails" do
  add_filter "/spec/"
  minimum_coverage 0  # start at 0, raise incrementally
end

# Inside RSpec.configure:
config.include FactoryBot::Syntax::Methods

# Add this module for request specs:
module AuthHelpers
  def auth_headers(user)
    { "Authorization" => "Bearer #{user.authentication_token}" }
  end
end
config.include AuthHelpers, type: :request
```

Add `gem "simplecov", require: false` to the `:test` group in `Gemfile`.

**1b. Fix broken factories**

Several factories have hardcoded IDs that will cause failures when multiple records exist:

```ruby
# spec/factories.rb — current (broken)
factory :vendor do
  user_id { 1 }   # will fail if user with id=1 doesn't exist
end

factory :organization do
  admin_user_id { 1 }  # same problem
end

# fix: use associations
factory :vendor do
  association :user
  business_name { FFaker::Company.name }
  business_email { FFaker::Internet.email }
  website { FFaker::Internet.http_url }
  location { FFaker::Address.city }
  category { "aac" }
  verified { false }
end

factory :organization do
  name { FFaker::Company.name }
  slug { FFaker::Internet.slug }
  association :admin_user, factory: :user
end
```

Also add a `:child_account` factory with a user association — the current one is empty:
```ruby
factory :child_account do
  association :user
  name { FFaker::Name.name }
end
```

---

### Phase 2 — Security-critical request specs (highest ROI, ~3 hours)

These directly cover the vulnerabilities identified in the improvement plan.

**2a. `spec/requests/api/auth_spec.rb`** (new file)

Covers: login flow, token returned, forgot_password enumeration fix, reset_password.

```ruby
RSpec.describe "API::Auth", type: :request do
  let!(:user) { create(:user, password: "password123") }

  describe "POST /api/v1/login" do
    it "returns 200 and an authentication token with valid credentials"
    it "returns 401 with invalid credentials"
    it "returns 401 when user does not exist"
  end

  describe "POST /api/v1/forgot_password" do
    # covers security issue 2b: email enumeration
    it "returns 200 whether or not the email exists" do
      post "/api/v1/forgot_password", params: { email: user.email }
      expect(response).to have_http_status(:ok)

      post "/api/v1/forgot_password", params: { email: "nobody@example.com" }
      expect(response).to have_http_status(:ok)  # must NOT return 404
    end

    it "returns the same response body whether or not the email exists" do
      post "/api/v1/forgot_password", params: { email: user.email }
      body_with_user = response.body

      post "/api/v1/forgot_password", params: { email: "nobody@example.com" }
      body_without_user = response.body

      # same message — doesn't leak account existence
      expect(JSON.parse(body_with_user)["message"]).to eq(JSON.parse(body_without_user)["message"])
    end
  end

  describe "POST /api/v1/reset_password" do
    it "resets the password with a valid token"
    it "returns 422 with an invalid token"
    it "returns 422 with a mismatched password confirmation"
  end
end
```

**2b. `spec/requests/api/images_spec.rb`** (new file)

Covers: auth enforcement, ORDER BY injection fix (1c in improvement plan), ownership.

```ruby
RSpec.describe "API::Images", type: :request do
  let!(:user)       { create(:user) }
  let!(:other_user) { create(:user) }
  let!(:image)      { create(:image, user: user) }

  describe "GET /api/images" do
    context "when unauthenticated" do
      it "returns 401" do
        get "/api/images"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated" do
      it "returns only images belonging to the current user" do
        create(:image, user: other_user)
        get "/api/images", headers: auth_headers(user)
        ids = JSON.parse(response.body)["data"].map { |i| i["id"] }
        expect(ids).to include(image.id)
        expect(ids).not_to include(other_user_image.id)
      end

      it "accepts valid sort_field params without error" do
        get "/api/images", params: { sort_field: "label", sort_order: "asc" },
            headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "ignores invalid sort_field params (SQL injection guard)" do
        get "/api/images", params: { sort_field: "id; DROP TABLE images; --", sort_order: "asc" },
            headers: auth_headers(user)
        # should not 500, should return results with a safe fallback sort
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "DELETE /api/images/:id" do
    it "returns 404 when trying to delete another user's image" do
      other_image = create(:image, user: other_user)
      delete "/api/images/#{other_image.id}", headers: auth_headers(user)
      expect(response).to have_http_status(:not_found).or have_http_status(:forbidden)
    end
  end
end
```

**2c. `spec/requests/api/boards_spec.rb`** (new file)

Covers: auth enforcement, ownership (user can't read/modify another user's board), CRUD basics.

```ruby
RSpec.describe "API::Boards", type: :request do
  let!(:user)       { create(:user) }
  let!(:other_user) { create(:user) }
  let!(:board)      { create(:board, user: user) }
  let!(:other_board){ create(:board, user: other_user) }

  describe "GET /api/boards/:id" do
    it "returns 401 when unauthenticated"
    it "returns the board for its owner"
    it "returns 404 or 403 when requesting another user's private board"
  end

  describe "POST /api/boards" do
    it "creates a board belonging to the current user"
    it "returns 401 when unauthenticated"
  end

  describe "PATCH /api/boards/:id" do
    it "updates the board for its owner"
    it "returns 403 or 404 when updating another user's board"
  end

  describe "DELETE /api/boards/:id" do
    it "deletes the board for its owner"
    it "returns 403 or 404 when deleting another user's board"
  end

  describe "GET /api/boards with sort params" do
    it "accepts valid sort_field without error"
    it "ignores unrecognized sort_field (SQL injection guard)" do
      get "/api/boards", params: { sort_field: "name; DROP TABLE boards;--" },
          headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
    end
  end
end
```

**2d. `spec/requests/api/admin/users_spec.rb`** (new file)

Covers: admin-only enforcement + ORDER BY injection in admin users controller.

```ruby
RSpec.describe "API::Admin::Users", type: :request do
  let!(:admin) { create(:user, role: "admin") }
  let!(:user)  { create(:user) }

  describe "GET /api/admin/users" do
    it "returns 401 when unauthenticated"
    it "returns 403 when authenticated as non-admin"
    it "returns 200 when authenticated as admin"

    it "ignores unsafe sort_field values" do
      get "/api/admin/users",
          params: { sort_field: "role; DROP TABLE users;--" },
          headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
    end
  end
end
```

---

### Phase 3 — Model specs for business logic (~2 hours)

**3a. Expand `spec/models/user_spec.rb`**

The current spec only covers validation and team invite. Add:

```ruby
describe "#premium?" do
  it "returns true when plan_type is 'premium' and plan_status is 'active'"
  it "returns false when plan_type is 'free'"
  it "returns false when plan has expired"
end

describe "#can_use_feature?" do
  it "returns true for free features regardless of plan"
  it "returns true for premium features when subscribed"
  it "returns false for premium features when on free plan"
end
```

**3b. Expand `spec/models/board_spec.rb`**

The current spec covers `find_or_create_images_from_word_list`. Add the next most important methods:

```ruby
describe "#clone_with_images" do
  it "creates a new board with the same name"
  it "copies all board_images to the new board"
  it "does not share board_image records (new records, same images)"
end

describe "#update_grid_layout" do
  it "stores positions keyed by screen size"
  it "does not error when layout is nil"
end
```

**3c. Fill in `spec/models/child_account_spec.rb`**

```ruby
describe "associations" do
  it "belongs to a user"
  it "can have many child_boards"
end

describe "validations" do
  it "is invalid without a name"
end
```

---

### Phase 4 — Sidekiq job specs (light, ~1 hour)

Delete the 7 pending stubs. The only jobs worth testing at the unit level are ones with non-trivial conditional logic. The rest are integration concerns better covered by request specs.

**Keep and fill in:**

`spec/sidekiq/create_subscription_job_spec.rb` — test that it calls Pay and creates a subscription record, stubs the Stripe call.

`spec/sidekiq/update_board_images_job_spec.rb` — test that it processes images for a board and handles missing boards gracefully.

**Delete (pending stubs with no value at unit level):**
- `create_custom_predictive_default_job_spec.rb`
- `create_predictive_board_job_spec.rb`
- `format_board_with_ai_job_spec.rb`
- `delete_image_job_spec.rb`
- `save_profile_audio_job_spec.rb`
- `update_user_boards_job_spec.rb`
- `import_from_obf_job_spec.rb` (the single real test is commented out; the job is better tested via the OBF import request endpoint)

---

## Summary of changes

| Action | Files | Reason |
|---|---|---|
| Delete | All 63 `test/` files | 100% stubs, wrong framework |
| Delete | `spec/controllers/api/boards_controller_spec.rb` | Entirely commented out |
| Delete | `spec/helpers/` (2 files) | Pending stubs; helpers too trivial to test |
| Delete | `spec/routing/scenarios_routing_spec.rb` | Covered by request specs |
| Delete | `spec/requests/api/webhooks_spec.rb` | Empty file |
| Delete | 7 of 9 sidekiq stubs | Pending with no content |
| Keep + expand | `spec/models/board_spec.rb` | Real tests; add clone + layout |
| Keep + expand | `spec/models/user_spec.rb` | Real tests; add subscription logic |
| Keep + expand | `spec/models/image_spec.rb` | Real tests; already decent |
| Keep | `spec/requests/api/board_images_rate_limit_spec.rb` | Well-written; keep as-is |
| Fill in | `spec/models/child_account_spec.rb` | Stub → real |
| Fill in | 2 sidekiq specs | Subscription + board image jobs |
| Add | `spec/requests/api/auth_spec.rb` | Login, forgot_password enumeration, reset |
| Add | `spec/requests/api/images_spec.rb` | Auth, ownership, SQL injection guard |
| Add | `spec/requests/api/boards_spec.rb` | Auth, ownership, CRUD |
| Add | `spec/requests/api/admin/users_spec.rb` | Admin enforcement, SQL injection guard |
| Update | `spec/rails_helper.rb` | Add SimpleCov + auth helper |
| Update | `spec/factories.rb` | Fix hardcoded IDs, add child_account |

After Phase 2 the most dangerous gaps (no auth enforcement tests, no SQL injection regression tests) are closed. Phases 3 and 4 add confidence for business logic changes.
