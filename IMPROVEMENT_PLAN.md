# SpeakAnyWay Backend — Improvement Plan

Ordered by ROI: critical security fixes first (high impact, low effort), then performance quick wins, then larger refactors.

---

## 1. Critical Security — Fix Immediately

### 1a. Sidekiq Web UI is publicly accessible
**File:** `config/routes.rb:526`

Anyone who can reach the server can view all job queues, job payloads (which contain user data), and trigger retries or deletions.

```ruby
# current
mount Sidekiq::Web => "/sidekiq"

# fix
authenticate :user, ->(u) { u.admin? } do
  mount Sidekiq::Web => "/sidekiq"
end
```

### 1b. RailsPerformance dashboard is publicly accessible
**File:** `config/routes.rb:530`, `config/initializers/rails_performance.rb:32`

The `verify_access_proc` is commented out. Uncomment and scope to admin users only.

### 1c. SQL injection via unvalidated ORDER BY params
**Files:** `app/controllers/api/images_controller.rb:21-23`, `app/controllers/api/admin/users_controller.rb:15`

`sort_field` and `sort_order` from `params` are interpolated directly into SQL strings or passed as hash keys to `order()` with no allowlist. The `boards` controller correctly uses `allowed_sort_fields` — the same pattern needs to be applied here.

```ruby
# images_controller.rb — current (vulnerable)
@images.order("#{sort_field} #{sort_order}")

# fix
ALLOWED_SORT_FIELDS = %w[label created_at updated_at].freeze
ALLOWED_SORT_ORDERS = %w[asc desc].freeze
sort_field = ALLOWED_SORT_FIELDS.include?(params[:sort_field]) ? params[:sort_field] : "created_at"
sort_order = ALLOWED_SORT_ORDERS.include?(params[:sort_order]) ? params[:sort_order] : "asc"
@images.order(sort_field => sort_order)
```

---

## 2. High Security — Fix Soon

### 2a. Static auth token never expires
**File:** `app/controllers/api/application_controller.rb`

The app uses a static `authentication_token` (from `has_secure_token`) rather than the JWT infrastructure already installed (`devise-jwt`). The static token never expires — a leaked token grants indefinite access.

Options (pick one):
- **Short-term:** Add a `token_expires_at` column to `users` and enforce expiry on every `user_from_token` call.
- **Longer-term:** Switch to the already-configured JWT flow. `devise-jwt` is installed and configured with a 30-minute expiry — it just isn't being used. The auth controller (`api/v1/auths_controller.rb:43`) returns the static token instead of the JWT.

### 2b. `forgot_password` leaks account existence
**File:** `app/controllers/api/v1/auths_controller.rb:73-82`

Returns `404 + "No user found"` vs `200 + "Instructions sent to <email>"` — lets anyone enumerate registered users. Fix: always return the same status and message regardless of whether the email exists.

### 2c. `reset_password` stores token in plaintext
**File:** `app/controllers/api/v1/auths_controller.rb:78`

```ruby
user.update(reset_password_token: reset_token)  # stores raw token
```

Devise hashes reset tokens before storing them — this custom implementation stores them in plaintext, so a database read reveals valid reset tokens. Use Devise's built-in `send_reset_password_instructions` instead of the manual flow.

### 2d. CSRF protection disabled globally
**File:** `app/controllers/application_controller.rb:25`

```ruby
skip_before_action :verify_authenticity_token
```

This skips CSRF protection for all HTML views, not just the API. Any session-based HTML route is vulnerable to cross-site request forgery. JSON API endpoints don't need CSRF tokens (token auth is immune), but HTML views do. Move the skip to `Api::ApplicationController` only.

---

## 3. Performance — Quick Wins

### 3a. Missing indexes on `images` table
**File:** `db/schema.rb`

The `images` table has no index on `user_id` or `label`, despite virtually every image query filtering by one or both:

```ruby
Image.where(user_id: current_user.id)
Image.find_by(label: label, user_id: current_user.id)
```

This is a full table scan on every image lookup. As the table grows this becomes the primary bottleneck.

```ruby
# migration
add_index :images, :user_id
add_index :images, [:user_id, :label]
```

Check for the same pattern on other high-traffic association columns (e.g. `board_images.board_id`, `board_images.image_id` — confirm these exist).

### 3b. N+1 queries in `add_to_groups` and `assign_accounts`
**File:** `app/controllers/api/boards_controller.rb:770-784, 799-811`

`add_to_groups` calls `BoardGroup.find_by` and `board_group.boards.include?` in a loop:
```ruby
# current
board_group_ids.each do |id|
  board_group = BoardGroup.find_by(id: id)        # N queries
  next if board_group.boards.include?(@board)      # N queries
end

# fix
board_groups = BoardGroup.includes(:boards).where(id: board_group_ids)
board_groups.each { |bg| bg.boards << @board unless bg.boards.include?(@board) }
```

`assign_accounts` calls `ChildAccount.find` + `clone_with_images` per account in the request cycle — the clone should be a background job (see 4b).

### 3c. Configure Redis as the production cache store
**File:** `config/environments/production.rb:94`

The cache store is not configured — `Rails.cache` calls fall back to an in-process store that is not shared across Puma workers or app instances. Redis is already available (used for Sidekiq and ActionCable).

```ruby
config.cache_store = :redis_cache_store, { url: ENV["REDIS_URL"] }
```

### 3d. `update_multiple` in `board_images_controller.rb` saves in a loop
**File:** `app/controllers/api/board_images_controller.rb:96-151`

Calls `board_image.save` per record — 50 board images = 50 individual SQL UPDATEs. Use `upsert_all` or wrap in a transaction at minimum.

---

## 4. Medium Priority — Architecture & Reliability

### 4a. Production config hardening
**File:** `config/environments/production.rb`

Three commented-out settings should be enabled:

| Setting | Line | Risk if disabled |
|---|---|---|
| `config.require_master_key = true` | 31 | App can boot without encryption key, potentially using unencrypted credentials |
| `config.assume_ssl = true` | 75 | `Secure` cookie flag and HSTS header may not be set |
| `config.hosts` allowlist | 123 | DNS rebinding protection is disabled |

### 4b. Board cloning in `assign_accounts` blocks the request
**File:** `app/controllers/api/boards_controller.rb:799-811`

`clone_with_images` is called synchronously per account inside the request. For boards with many images and many accounts this will time out. Move to a Sidekiq job:

```ruby
communicator_account_ids.each do |account_id|
  CloneBoardForAccountJob.perform_async(@board.id, account_id, current_user.id)
end
render json: { message: "Board assignment queued" }
```

### 4c. Hardcoded admin email fallback
**File:** `app/mailers/admin_mailer.rb:13, 21`

```ruby
to_email = ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"
```

Remove the hardcoded fallback. If `ADMIN_EMAIL` is unset, raise a configuration error at boot rather than silently emailing a personal address.

### 4d. CORS config cleanup
**File:** `config/initializers/cors.rb`

- Remove `http://192.168.11.65:8100` — a developer's local IP should not be in any environment's config. Use `.env.local` instead.
- Change `http://app.speakanyway.com` to `https://` — the HTTP origin is redundant since `force_ssl` is on.

### 4e. `Redis.current=` is deprecated
**File:** `config/initializers/redis.rb:8`

`Redis.current=` is deprecated in redis-rb 5.x. Replace with a `ConnectionPool` or use `Redis.new` per call site.

---

## 5. Code Quality — Larger Refactors

### 5a. Break up `Board` model (2617 lines)
**File:** `app/models/board.rb`

Responsibilities to extract as concerns or service objects:
- OBF/OBZ import + export → `app/services/obf/` (partial work already started)
- Audio generation → `AudioHelper` concern already exists, could be a service
- AI word suggestions → `app/services/boards/ai_word_suggester.rb`
- Clone/copy logic → `app/services/boards/cloner.rb`
- PDF/preview generation → `app/services/boards/preview_generator.rb`

Tackle one slice at a time. Start with OBF (it has a standalone service directory) and clone logic (needed for the async fix in 4b).

### 5b. Move `OpenAiClient` out of `app/models/`
**File:** `app/models/open_ai_client.rb` (765 lines)

This is a plain Ruby service class — no ActiveRecord, no persistence. It belongs in `app/services/open_ai_client.rb`. The `app/services/` directory already exists. This is a rename + move — no logic changes required.

### 5c. `boards_controller.rb` is 1167 lines with 30+ actions
**File:** `app/controllers/api/boards_controller.rb`

Actions to extract into dedicated controllers:
- `import_obf`, `download_obf` → `Api::BoardObfController`
- `format_with_ai`, `generate_board` → `Api::BoardAiController`
- `assign_accounts`, `add_to_groups` → `Api::BoardAssignmentsController`

Each extracted controller is ~50-100 lines. This also makes it much easier to scope authorization correctly per controller.

### 5d. Consolidate duplicate auth token lookup
**Files:** `app/controllers/api/application_controller.rb`, `app/controllers/api/admin/application_controller.rb`

`user_from_token`, `admin_from_token`, and `child_from_token` all independently implement the same bearer token lookup pattern. Extract a shared `TokenAuthenticatable` concern and include it in all three base controllers.

### 5e. Unify background job base class
**File:** `app/jobs/` (34 files)

Jobs use `Sidekiq::Worker` directly with no shared base class. There is no consistent error handling, logging, or retry configuration. Create `ApplicationJob < ActiveJob::Base` with `sidekiq_options retry: 3` and standard error logging, then inherit from it. Rails already generates `ApplicationJob` — the jobs just don't use it.

---

## 6. Test Coverage

The test suite has 113 files split across two frameworks (RSpec in `spec/`, Minitest in `test/`) with no coverage tracking and significant duplication between them.

**Recommended approach:**
1. Pick one framework (RSpec is more commonly used in this stack given the `spec/` directory and the existing model specs) and delete the Minitest stubs in `test/` that have no content.
2. Add SimpleCov: `gem "simplecov"` with a target of 80% on `app/controllers/api/` and `app/models/`.
3. Prioritize request specs for the highest-risk controllers:
   - `spec/requests/api/auth_spec.rb` — covers 2a, 2b, 2c above
   - `spec/requests/api/images_spec.rb` — covers SQL injection fix (1c)
   - `spec/requests/api/boards_spec.rb` — N+1 and permission checks
4. Add model specs for `Board` before beginning the refactor in 5a — they provide a safety net.

---

## Priority Summary

| # | Item | Effort | Impact |
|---|---|---|---|
| 1a | Lock down Sidekiq Web UI | 15 min | Critical |
| 1b | Lock down RailsPerformance dashboard | 15 min | Critical |
| 1c | Fix SQL injection in ORDER BY | 30 min | Critical |
| 2b | Fix `forgot_password` enumeration | 20 min | High |
| 2c | Fix plaintext reset token | 30 min | High |
| 3a | Add `images.user_id` index | 15 min | High |
| 3c | Configure Redis cache store | 10 min | Medium |
| 4a | Enable commented-out production config | 15 min | Medium |
| 4c | Remove hardcoded admin email | 10 min | Low |
| 4d | Fix CORS config | 10 min | Low |
| 2a | Token expiry / JWT migration | 2–4 hrs | High |
| 2d | Scope CSRF skip to API controller only | 1 hr | High |
| 3b | Fix N+1 in `add_to_groups` | 1 hr | Medium |
| 3d | Batch `update_multiple` saves | 1 hr | Medium |
| 4b | Async board cloning in `assign_accounts` | 2 hrs | Medium |
| 5b | Move `OpenAiClient` to services | 30 min | Low |
| 5d | Consolidate auth token lookup concern | 2 hrs | Low |
| 5e | Unify job base class | 2 hrs | Low |
| 5a | Break up `Board` model | 1–2 weeks | Medium |
| 5c | Split `boards_controller.rb` | 3–5 days | Medium |
| 6 | Test coverage (request specs + SimpleCov) | Ongoing | High |
