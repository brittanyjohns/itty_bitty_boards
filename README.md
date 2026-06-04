# Speak Anyway

## Empowering communication through the power of AI

- Ruby version: 3.0.1

- System dependencies:

  - postgresql
  - redis
  - imagemagick
  - ffmpeg

- Environment Variables:

  - `AWS_ACCESS_KEY_ID` - AWS Access Key ID
  - `AWS_SECRET_ACCESS_KEY` - AWS Secret Access Key
  - `AWS_REGION` - AWS Region
  - `API_URL` - API URL (for OBF exports)
  - `OPENAI_ACCESS_TOKEN` - OpenAI Access Token
  - `OPENAI_ORGANIZATION` - OpenAI Organization (optional)
  - `STRIPE_PUBLIC_KEY` - Stripe Public Key
  - `STRIPE_PRIVATE_KEY` - Stripe Private Key
  - `STRIPE_SIGNING_SECRET` - Stripe Signing Secret
  - `STRIPE_WEBHOOK_SECRET` - Stripe Webhook signing secret (separate from STRIPE_SIGNING_SECRET; used by `/api/webhooks`)
  - `STRIPE_PRICE_TOPUP_SMALL` - Stripe Price ID for the small credit pack (100 credits)
  - `STRIPE_PRICE_TOPUP_MEDIUM` - Stripe Price ID for the medium credit pack (500 credits)
  - `STRIPE_PRICE_TOPUP_LARGE` - Stripe Price ID for the large credit pack (1500 credits)
  - `CDN_HOST` - CDN Host (optional)
  - `DEVISE_JWT_SECRET_KEY` - Devise JWT Secret Key
  - `DOMAIN` - Domain
  - `GOOGLE_CUSTOM_SEARCH_API_KEY` - Google Custom Search API Key
  - `GOOGLE_CUSTOM_SEARCH_CX` - Google Custom Search CX
  - `PREDICTIVE_DEFAULT_ID` - Predictive Default ID (going to be removed)
  - `INTERNAL_API_KEY` - Shared key used to authenticate the internal API (see "Internal API" section below)

- Database creation:

  - `rails db:create`
  - `rails db:migrate`

- Database initialization:

  - `rails db:seed`

- How to run the test suite:

  - `bundle exec rspec`

- Services (job queues, cache servers, search engines, etc.):

  - `bin/dev`

- Deployment instructions:
  Deployed to Hatchbox.io

  - **Production:** auto-deploys when `main` advances → `speakanyway.com`
    (Hatchbox app `670kd.hatchboxapp.com`).
  - **Staging:** label any PR with `deploy-to-staging` to push it to the
    `staging` branch and deploy to `https://ypk9e.hatchboxapp.com`. The
    `.github/workflows/staging-deploy.yml` workflow force-pushes the PR's
    HEAD to `staging` and triggers Hatchbox via API.
  - **Staging env vars** are managed in GitHub Actions secrets and pushed to
    Hatchbox via the `Sync staging env vars to Hatchbox` workflow
    (`.github/workflows/staging-sync-env.yml`). The list of names lives in
    `script/hatchbox/staging_env_vars.yml`. Run that workflow after changing
    any staging secret.
  - Required GitHub secrets for the staging workflows:
    `HATCHBOX_API_TOKEN`, `HATCHBOX_ACCOUNT_ID`, `HATCHBOX_STAGING_APP_ID`,
    plus the `STAGING_*` set listed in `staging-sync-env.yml`.

Features

Multiple ways of creating a communication board

- By hand: Add words one at a time
- From a word list: Input a list of words to create images from
- From a scenario: Describe a scenario and we'll use AI to generate a list of words
- From a menu: Upload a menu and we'll use AI to generate a communication board - Order with confidence!

AI powered word suggestions

- Use our AI to suggest words based on a scenario
- Use our AI to suggest words based on a list of words

Customizable communication boards

- Made to fit any size screen - Unique layouts for each screen size (small, medium, large)
- Resizable cells to provide emphasis or easy access to common selections
- Choose from 6 natural sounding voices
- Colored cells based on part of speech

Images - Search, upload, or generate images for your boards

- Search for images with our built-in Google image search
- Upload your own images
- Generate images from text using AI
- Browse our library of images

Communicator accounts

- Create communicator accounts to manage their access & content
- Share boards with communicator accounts
- Monitor usage and progress
- View usage statistics & word patterns
- Manage everything from your parent account, on any device
- Update boards in real-time

Subscription based service

- Free trial available
- Monthly or yearly subscription options
- Cancel anytime

## AI credits

AI features (image generation, scenario builder, menu builder, screenshot
imports, image edits/variations, word suggestions, board formatting) are gated
by an **AI credit** balance, not a flat monthly action cap. Each feature
charges a weighted number of credits — see `CreditService::FEATURE_COSTS` in
[`app/services/credit_service.rb`](app/services/credit_service.rb).

Two balances per user:

- **Plan credits** — granted at each billing-period renewal; expire at
  period end and do not roll over.
- **Top-up credits** — purchased ad hoc via Stripe Checkout; do not expire.

When a user runs out, AI endpoints return `402 insufficient_credits` with the
needed/balance numbers — the frontend uses that to surface a "Buy more
credits" CTA. `429 limit_reached` is reserved for true rate limiting.

### Pricing

> Numbers below are the defaults baked into `CreditService` and the staging
> Stripe Prices. Production tier prices and final allowances are a
> marketing/leadership decision — values are overridable per environment
> via Stripe Price metadata (`monthly_credits` on subscription Prices,
> `credit_amount` on top-up Prices) without a redeploy.
> See `docs/credits-handoff.md` for the working pricing proposal and the
> rationale behind these numbers.

**Plan tier allowances** (`CreditService::PLAN_MONTHLY_CREDITS`):

| Plan         | Monthly credits |
| ------------ | --------------- |
| Free         | 10              |
| MySpeak      | 50              |
| Basic        | 400             |
| Pro          | 1,500           |
| Partner Pro  | 1,500           |

**Top-up packs** (one-time Stripe Checkout, do not expire):

| Pack    | Credits | Price (USD) | `pack_key` |
| ------- | ------- | ----------- | ---------- |
| Small   | 100     | $4.99       | `small`    |
| Medium  | 500     | $19.99      | `medium`   |
| Large   | 1,500   | $49.99      | `large`    |

**Per-feature credit cost** (`CreditService::FEATURE_COSTS`, server-authoritative):

| Feature                    | `feature_key`        | Credits |
| -------------------------- | -------------------- | ------- |
| AI word suggestions        | `word_suggestion`    | 1       |
| AI board formatting        | `board_format`       | 2       |
| AI image edit              | `image_edit`         | 3       |
| AI image variation         | `image_variation`    | 3       |
| AI image generation        | `image_generation`   | 5       |
| AI screenshot import       | `screenshot_import`  | 5       |
| AI scenario builder        | `scenario_create`    | 10      |
| AI menu builder            | `menu_create`        | 10      |

### Stripe setup

Each subscription Price in Stripe must have metadata:

- `plan_type`: one of `free`, `myspeak`, `basic`, `pro`, `partner_pro`
- `monthly_credits`: integer; overrides `CreditService::PLAN_MONTHLY_CREDITS`
  defaults

Each top-up Price must have metadata:

- `kind: "topup"`
- `credit_amount`: integer

See `docs/stripe-setup.md` for the full dashboard checklist.

### API surface

- `GET /api/me/credits` — `{ plan, topup, total, reset_at, plan_type }`
- `GET /api/me/credit_transactions` — paginated ledger
- `POST /api/stripe/checkout_sessions/topup` — creates a one-time Stripe
  Checkout Session for a credit pack. Body: `{ pack_key: "small"|"medium"|"large", quantity: 1 }`.
  On payment success, the webhook adds credits to `topup_credits_balance`
  (idempotent on Stripe event id).

### Status

**Phases 1–4 are live.** `CreditService.spend!` is the source of truth
for AI gating; AI endpoints return `402 insufficient_credits` when a call
would overdraw. Plan credits are granted automatically by Stripe
webhooks:

- `invoice.payment_succeeded` → grant for the new billing period
  (initial payment + every renewal). Idempotent on Stripe event id.
- `customer.subscription.created` with status `trialing` → grant for the
  trial period.
- `customer.subscription.deleted` / `.paused` → expire plan credits
  (top-up credits preserved).
- Hourly `ExpirePlanCreditsJob` as a backstop.

Admins bypass the credit check. `MonthlyFeatureLimiter` is no longer in
the AI hot path.

## SpeakAnyWay-Specific Terms:

1. Board: A customizable grid layout where users can place words, phrases, or images to facilitate communication.
   a. Static Board: A board with fixed content that does not change screens, regardless of the image that is clicked.

b. Dynamic Board: A board that _can_ change screens - This is based on the image that is clicked.

2. Image: Visual elements added to boards to represent words, phrases, or concepts, often sourced via the Google Image Search API or uploaded by users.
   a. Predictive Board - The board that will display when the image is clicked & the board is dynamic.
   b. Image Generation: The process of creating an image from text, powered by AI.
   c. Image Search: The process of finding images via the Google Image Search API.
   d. Image Upload: The process of adding images to the SpeakAnyWay platform.

3. Word List: A list of words or phrases that can be used to generate a communication board.

4. Word Suggestions: A list of words or phrases generated by AI based on a scenario or word list.

5. BoardImage: An image that is associated with a board, used to represent the board in the user interface. Used to customize images per board.

6. Voice: The audio output used to read the text on the board. Users can choose from a selection of voices to customize the experience. These currently come from OpenAI.

7. Part of Speech: The grammatical category of a word, such as a noun, verb, adjective, or adverb. This feature is used to color-code cells on the board based on the part of speech of the word.

8. Usage Statistics: Data on how a board is used, including the number of times it is accessed, the most frequently accessed cells, and other relevant metrics.

9. Parent Account: The primary account holder, responsible for managing communicator accounts, subscriptions, and other account-related features.

10. Communicator Account: A user profile designed for a communicator, allowing caregivers to manage and customize the content and features for that specific user.

11. Subscription: A paid service that provides access to premium features, such as ad-free experience, AI image generation, and other exclusive tools or functionalities.

12. Menu Board Creator: A premium feature enabling users to generate communication boards from a menu image. The uploaded photo is read directly by an AI vision model, which extracts the menu items the board is built from.

13. Scenario: A user-generated description of a situation or context, used to generate a list of words or phrases that may be relevant to that scenario. This feature is powered by AI.

14. Premium Features: Exclusive tools or functionalities available to paying subscribers (e.g., ad-free experience, AI image generation).

15. AI: Artificial Intelligence, used to generate word suggestions, images, and other content on the platform. This feature is powered by OpenAI.

## Internal API

A small, internal-only API mounted under `/api/internal/`. Used for trusted
server-to-server calls (scripts, internal tools) — not for the React frontend
and not exposed to end users.

### Authentication

All requests must include a bearer token matching `ENV["INTERNAL_API_KEY"]`:

```
Authorization: Bearer <INTERNAL_API_KEY>
```

Missing or incorrect tokens return `401 Unauthorized`. There is no per-user
auth; every write is performed as the default admin user
(`User::DEFAULT_ADMIN_ID`).

### Setup

Generate a strong random key and add it to your environment:

```sh
# Generate
bin/rails runner 'puts SecureRandom.hex(32)'

# .env (local)
INTERNAL_API_KEY=<the generated value>
```

For Hatchbox, set `INTERNAL_API_KEY` in the app's environment variables panel.

### Endpoints

#### `POST /api/internal/boards`

Creates a board, then optionally enqueues `GenerateBoardJob` based on
`board_creation_type` — same dispatch as the public `POST /api/boards`.

The board is owned by the default admin (`User::DEFAULT_ADMIN_ID`).

**Top-level params**

- `board_creation_type` *(optional, default `"default"`)* — one of `"default"`, `"scenario"`, or any other string. Determines what (if anything) is enqueued; also overwrites `board.board_type` after `assign_parent`.
- `word_list` *(default branch only)* — array of strings. If present, enqueues `GenerateBoardJob` with the list. If omitted, no job is enqueued.
- `topic`, `age_range` (or `ageRange`), `word_count` (or `wordCount`) *(scenario branch)* — passed straight to the job.
- `word_count` *(other branches)* — defaults to 12.
- `voice` / `voice_label` — fallback if `board[voice]` isn't set.

**Default — pure record create (no job enqueued):**

```sh
curl -X POST https://<host>/api/internal/boards \
  -H "Authorization: Bearer $INTERNAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "board": {
      "name": "My Board",
      "board_type": "static",
      "voice": "alloy",
      "language": "en"
    }
  }'
```

**Default — with a `word_list` (enqueues `GenerateBoardJob` to find/create images for each word):**

```sh
curl -X POST https://<host>/api/internal/boards \
  -H "Authorization: Bearer $INTERNAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "board": { "name": "Snacks" },
    "word_list": ["apple", "banana", "carrot"]
  }'
```

**Scenario — generate words from a topic:**

```sh
curl -X POST https://<host>/api/internal/boards \
  -H "Authorization: Bearer $INTERNAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "board": { "name": "Coffee Shop" },
    "board_creation_type": "scenario",
    "topic": "ordering coffee",
    "age_range": "10-15",
    "word_count": 16
  }'
```

Response: `201 Created` with the created board. Generation runs async via Sidekiq.

##### `board_creation_type` reference

`board_creation_type` is a free-form string. The controller switches on it to
decide which params to forward to `GenerateBoardJob`. The job then switches on
the same string to decide how to produce a list of words. Both switches must
agree, so in practice only the values below are usable from the internal API.

After words are produced (by any branch), the job runs the same finishing
sequence:

1. `Board.find_or_create_images_from_word_list(words)` — for each word, finds an existing image (user-owned, then admin-owned) or creates a new one. If the image has no displayable doc and no admin/user copy, schedules `GenerateImagesJob` (which calls OpenAI image gen in batches of 3).
2. `Board#reset_layouts` — re-flows the grid for all screen sizes.
3. `Board#generate_previews` — re-renders the board's preview image.
4. `board.status` advances `generating_words` → `finding_images` → `processing` → `complete`.

If the branch produces zero words, the job logs a warning and jumps straight to
`complete` (no images are created).

###### `default` *(default)*

- **Word source:** the `word_list` array you POST. No OpenAI call for words.
- **Required params:** `word_list` *(array of strings)*. If omitted, **no job is enqueued at all** — the board is created empty.
- **Other params forwarded to job:** none.
- **Use when:** you already have the exact words you want.

```json
{ "board": { "name": "Snacks" }, "word_list": ["apple", "banana", "carrot"] }
```

###### `scenario`

- **Word source:** OpenAI, via `Board#get_words_for_scenario(topic, age_range, word_count)`.
- **Prompt sent to OpenAI:**
  > Generate a list of words for a communication board. The topic or theme of the board is **{topic}**. The name of the board is **{board.name}**. The age range for the person using the board is **{age_range}**. Please provide a list of **{word_count}** words that are appropriate for this age range and context. Exclude words that are too similar to each other or that would not be useful on a communication board. Also exclude words that are already on the board: **{current_words}**.
- **Required params:** `topic` *(string)*. Falls back to `prompt`, then `board.name`.
- **Optional params:** `age_range` (or `ageRange`), `word_count` (or `wordCount`, default `12`).
- **Word count clamping:** the job clamps `word_count` to `1..80`. Out-of-bounds values fall back to `large_screen_columns * 4` (and the model itself defaults to `24` if it sees the same condition).
- **Use when:** you have a topic/theme but no specific words.

```json
{
  "board": { "name": "Coffee Shop" },
  "board_creation_type": "scenario",
  "topic": "ordering coffee",
  "age_range": "10-15",
  "word_count": 16
}
```

###### `predictive`

- **Word source:** OpenAI, via `Board#get_words_for_predictive(starting_phrase_or_word, word_count)` *if* no `word_list` is provided. Otherwise the supplied `word_list` is used directly.
- **Prompt sent to OpenAI:**
  > Generate a list of **{word_count}** words that would commonly follow the **{word|phrase}** **'{starting_phrase_or_word}'** in everyday communication. These words will be used on a predictive communication board to help users quickly find and select common phrases. Please provide words that are relevant and commonly used in conjunction with **'{starting_phrase_or_word}'**.
- **Required params:** `starting_phrase_or_word` (or `startingPhraseOrWord`) when no `word_list` is given.
- **Optional params:** `word_list` (skip the OpenAI call), `word_count` (default `12`).

```json
{
  "board": { "name": "After 'I want'" },
  "board_creation_type": "predictive",
  "starting_phrase_or_word": "I want",
  "word_count": 12
}
```

###### `menu`

- Recognized by the job, but the branch is a placeholder that returns an empty word list — the board jumps straight to `complete` with zero images. Equivalent to creating a board with no `word_list` under `default`.

###### Anything else

- The job's fallback branch behaves like `default` (uses the supplied `word_list`, no OpenAI). The internal controller's fallback branch only forwards `word_count` and no `word_list`, so this combination produces an empty word list and a no-op completion. Stick to `default` or `scenario` from the internal API.

###### Side effect on `board.board_type`

Regardless of what you pass in `board[board_type]`, the controller overwrites
`board.board_type` with the `board_creation_type` value *after* `assign_parent`
runs. That mirrors the public `POST /api/boards` behavior. So a request with
`board_creation_type: "scenario"` ends with `board.board_type == "scenario"`.

#### `GET /api/internal/boards/:id`

Returns a single board's full API view (same payload shape as `PATCH`'s response).
Useful for confirming a board exists and inspecting its current images/layout
before posting cells or layout updates.

```sh
curl -H "Authorization: Bearer $INTERNAL_API_KEY" \
  https://<host>/api/internal/boards/123
```

Response: `200 OK` with the board's full API view, or `404 Not Found` if no
board has that id.

#### `PATCH /api/internal/boards/:id`

Updates board attributes. Accepts an optional `layout` parameter to persist a
grid layout for a screen size; this triggers the same layout-save flow used by
the public API (board image positions, cell sizes, screen-size column counts,
margins, per-screen settings, and a preview-image regenerate).

**Layout item shape** — each entry in `layout` describes one cell on the grid:

- `i` — the `BoardImage` id (string).
- `x`, `y` — grid coordinates (column / row), zero-indexed.
- `w`, `h` — how many columns / rows the cell spans. Defaults are `1`/`1`.

**Layout units.** `w` and `h` are grid units, not pixels. The grid is
`{small,medium,large}_screen_columns` wide. To create a wide cell that holds a
longer label, increase `w`. To stack rows, increase `h`. Layout is per screen
size, so resize cells separately for `sm` / `md` / `lg` if a label needs more
room on smaller screens.

```sh
curl -X PATCH https://<host>/api/internal/boards/123 \
  -H "Authorization: Bearer $INTERNAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "board": { "name": "Renamed" },
    "screen_size": "lg",
    "layout": [
      { "i": "101", "x": 0, "y": 0, "w": 3, "h": 1 },
      { "i": "102", "x": 3, "y": 0, "w": 1, "h": 1 }
    ],
    "small_screen_columns": 3,
    "medium_screen_columns": 6,
    "large_screen_columns": 8,
    "xMargin": 4,
    "yMargin": 4
  }'
```

In this example, cell `101` is three columns wide (room for a longer label like
`"french fries"`), and cell `102` sits next to it at `x: 3` as a normal 1×1 cell.

`layout` may also be passed in object form: `{ "screen_size": "lg", "layout": [...] }`.

Response: `200 OK` with the board's full API view.

#### `GET /api/internal/boards/:id/export.pdf`

Renders the board as a PDF (Letter, Grover/Chromium under the hood) and returns
it as an attachment download. The same template the public `/api/boards/:id/pdf`
endpoint uses, with the QR code optional and overrideable.

**Query params**

- `qr_code` *(default `false`)* — boolean. Set to `true` to include a QR code in the header.
- `qr_target_url` *(optional)* — when `qr_code=true`, the URL the QR code should encode. If omitted, falls back to the board's own public URL (the same default the public PDF endpoint uses).
- `screen_size` *(default `"lg"`)* — which screen-size layout to render.
- `hide_colors` *(default `"0"`)* — `"1"` to render the grid in black and white.
- `hide_header` *(default `"0"`)* — `"1"` to hide the entire header row (logo, title, QR section).

```sh
curl -L -o board-123.pdf \
  -H "Authorization: Bearer $INTERNAL_API_KEY" \
  "https://<host>/api/internal/boards/123/export.pdf?qr_code=true&qr_target_url=https%3A%2F%2Fexample.com%2Fclaim%2Fabc"
```

Response: `200 OK` with `Content-Type: application/pdf` and
`Content-Disposition: attachment; filename="<board-slug>-board.pdf"`.

#### `POST /api/internal/boards/:id/board_images`

Adds a single cell (a `BoardImage`) to a board. Equivalent to one iteration of
`Board#find_or_create_images_from_word_list`, but exposed as a discrete call so
internal scripts can build a board cell-by-cell.

**Body params**

- `image_id` *(preferred)* — id of an existing `Image`. Used directly.
- `label` *(fallback)* — used only if `image_id` is omitted. Looks up an admin/user-owned `Image` by label, then a public image, then creates a new admin-owned image with that label.
- `position` *(optional)* — integer used to set `BoardImage#position` after creation. If omitted, the cell is appended at `board_images_count` (its existing default).
- `voice` *(optional)* — overrides the cell's voice. Normalized via `VoiceService`.
- `language` *(optional)* — overrides the cell's language code.

If neither `image_id` nor `label` is given, the request returns `422`.
Duplicate cells (same image already on the board) are allowed — the model
permits multiple `BoardImage` rows per `(board_id, image_id)` pair.

The cell's grid placement is auto-assigned by `BoardImage#set_initial_layout!`
across all screen sizes; use `PATCH /api/internal/boards/:id` with a `layout`
to move cells into specific positions afterward.

```sh
curl -X POST https://<host>/api/internal/boards/123/board_images \
  -H "Authorization: Bearer $INTERNAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{ "label": "apple", "position": 0 }'
```

Response: `201 Created` with the new `BoardImage`'s `api_view`.

#### `POST /api/internal/generated_boards`

Creates a board and enqueues `GenerateFreeBoardJob` to fill it with AI-generated
words and images for the given topic. The board is owned by the default admin
user (`User::DEFAULT_ADMIN_ID`); unlike the public `/api/generated_boards`
endpoint, no `generated_token` is issued and the board is not claimable.

```sh
curl -X POST https://<host>/api/internal/generated_boards \
  -H "Authorization: Bearer $INTERNAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "topic": "snacks",
    "age_range": "5-10",
    "word_count": 12
  }'
```

Optional params: `name` (defaults to `"<topic> (Age Range: <age_range>)"`),
`age_range`, `word_count` (defaults to `12`).

Response: `201 Created` with `{ id, name, status: "generating" }`. Poll the
board via the existing board endpoints to see when generation finishes.

#### `POST /api/internal/images`

Creates an image record without generating any AI image. Reuses an existing
image if one with the same label already exists for the admin user.

```sh
curl -X POST https://<host>/api/internal/images \
  -H "Authorization: Bearer $INTERNAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{ "image": { "label": "apple", "image_prompt": "a red apple" } }'
```

Response: `201 Created`.

#### `POST /api/internal/images/generate`

Enqueues a `GenerateImageJob` to call OpenAI and attach the resulting image.
Returns immediately (`202 Accepted`) with the image record in `generating`
state — see the "Polling for generation status" section below.

```sh
curl -X POST https://<host>/api/internal/images/generate \
  -H "Authorization: Bearer $INTERNAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "image": { "label": "apple", "image_prompt": "a red apple" },
    "transparent_background": "true"
  }'
```

Optional params: `id` (regenerate an existing image), `board_id`,
`screen_size`, `transparent_background`.

Response: `202 Accepted` with `{ id, label, status: "generating", ... }`.

#### `GET /api/internal/images/:id`

Returns the current state of an image. Used to check whether a previously
queued generation has finished.

```sh
curl https://<host>/api/internal/images/456 \
  -H "Authorization: Bearer $INTERNAL_API_KEY"
```

Response shape:

```json
{
  "id": 456,
  "label": "apple",
  "status": "complete",
  "image_prompt": "a red apple",
  "src": "https://.../apple.png",
  "error": null
}
```

`status` will be `generating`, `complete`, or `failed`.

### Polling for generation status

OpenAI image calls take several seconds and can occasionally exceed proxy
timeouts, so generation is intentionally async. After calling
`POST /api/internal/images/generate`, poll `GET /api/internal/images/:id`
until `status` is `complete` or `failed`:

```ruby
require "net/http"
require "json"

key = ENV.fetch("INTERNAL_API_KEY")
host = "https://<host>"

resp = Net::HTTP.post(
  URI("#{host}/api/internal/images/generate"),
  { image: { label: "apple", image_prompt: "a red apple" } }.to_json,
  "Authorization" => "Bearer #{key}",
  "Content-Type" => "application/json",
)
image_id = JSON.parse(resp.body).fetch("id")

loop do
  sleep 2
  status_resp = Net::HTTP.get_response(
    URI("#{host}/api/internal/images/#{image_id}"),
    "Authorization" => "Bearer #{key}",
  )
  body = JSON.parse(status_resp.body)
  break body if %w[complete failed].include?(body["status"])
end
```

## OBF / OBZ import & export

SpeakAnyWay can import and export boards in the [Open Board Format](https://www.openboardformat.org/)
— `.obf` (a single board, JSON) and `.obz` (a ZIP package of multiple linked
boards plus their image/sound assets). This is how boards move between
SpeakAnyWay and other AAC apps (CoughDrop, etc.).

These routes live under `namespace :api` and require a normal authenticated
user session (JWT) — they are **not** part of the internal API key surface.

| Method & path | Action | What it does |
|---|---|---|
| `POST /api/boards/import_obf` | `BoardsController#import_obf` | Import an `.obz` file **or** inline OBF JSON |
| `POST /api/boards/analyze_obz` | `BoardsController#analyze_obz` | Inspect an `.obz` package without importing |
| `GET /api/boards/:id/download_obf` | `BoardsController#download_obf` | Export one board as an `.obf` file |

### Copyright / image-license policy (read this first)

OBF packages from other apps often bundle **licensed symbol artwork**
(SymbolStix, PCS, etc.). To avoid silently pulling that artwork into our
public image pool, imports are gated:

- **Default — structure only, no binaries.** Without opt-in, the board
  structure (buttons, layout, labels) is imported and `Image` rows are
  created, but **no image binaries are downloaded or attached**. Every
  newly-created `Image` is `is_private: true`, regardless of opt-in. Existing
  images matched by label are reused as-is (we don't downgrade their
  visibility).
- **Opting into image binaries.** The client must send **both**
  `include_images=true` **and** `image_license_acknowledged=true`. Sending
  `include_images=true` without the acknowledgement returns
  **HTTP 400 `image_license_required`**. With both flags, the importer
  downloads/decodes each OBF image and attaches it.
- **Audit trail.** Every import records consent on
  `BoardGroup.settings["imported_from_obf"]`: `include_images`,
  `license_acknowledged`, `acknowledged_by_user_id`, `acknowledged_at`,
  `imported_by_user_id`, and the root board's OBF `license` block if present.

### Importing — `POST /api/boards/import_obf`

Accepts one of two inputs:

- **`file`** — a multipart `.obz` upload. Imported **synchronously** by
  `ObzImporter`: a `BoardGroup` is created, every `.obf` board inside is
  imported, `load_board` references are linked into navigable predictive
  boards, and the audit block is persisted. Returns the new
  `board_group_id` and `root_board_id`.
- **`data`** — inline OBF JSON for a single board. Queued to the
  **`ImportFromObfJob`** Sidekiq worker (async); the board appears with
  `status: "importing"` and flips to `active`/`error` when the job finishes.

| Param | Required | Notes |
|---|---|---|
| `file` | one of `file`/`data` | `.obz` upload (other extensions → 422) |
| `data` | one of `file`/`data` | Inline OBF JSON (single board) |
| `group_name` | no | Names the created `BoardGroup` (file path only) |
| `board_group_id` | no | Attach inline import to an existing group |
| `include_images` | no | Opt in to downloading image binaries (default `false`) |
| `image_license_acknowledged` | no | Must be `true` when `include_images=true` |

Responses:

- `200 OK` (file): `{ status, message, board_group_id, root_board_id, include_images }`
- `200 OK` (data): `{ status, message, include_images }` (job enqueued)
- `400 image_license_required` — `include_images=true` without acknowledgement
- `422` — unsupported file format, invalid JSON, or no file/data provided

```bash
# Structure only (default, no image binaries)
curl -X POST https://<host>/api/boards/import_obf \
  -H "Authorization: Bearer <user-jwt>" \
  -F "file=@board-set.obz" \
  -F "group_name=My imported set"

# Include image binaries — both flags required
curl -X POST https://<host>/api/boards/import_obf \
  -H "Authorization: Bearer <user-jwt>" \
  -F "file=@board-set.obz" \
  -F "include_images=true" \
  -F "image_license_acknowledged=true"
```

### Analyzing — `POST /api/boards/analyze_obz`

A dry-run inspector (`ObzAnalyzer`) for an `.obz` upload. Reads the package
**without importing anything** and returns a report — `package` overview,
`manifest`, resolved `root_board`, aggregate `totals`, per-board stats, and a
`warnings` array (missing media refs, non-string IDs, unresolved manifest
paths, duplicate asset IDs). Useful for previewing a package or debugging a
failed import.

```bash
curl -X POST https://<host>/api/boards/analyze_obz \
  -H "Authorization: Bearer <user-jwt>" \
  -F "file=@board-set.obz"
```

### Exporting — `GET /api/boards/:id/download_obf`

Serializes one board to OBF 0.1 JSON (`Board#to_obf`) and returns it as a
`board.obf` attachment (`application/json`). The payload follows the OBF spec
— `grid`, `buttons`, `images`, and `sounds` — with `load_board` links emitted
for predictive sub-boards. The exported `license` defaults to **CC BY-SA 4.0**
unless the board sets its own. Export is **not** gated by the import image
policy.

```bash
curl -X GET https://<host>/api/boards/<board_id>/download_obf \
  -H "Authorization: Bearer <user-jwt>" \
  -o board.obf
```

### Where the code lives

- `app/controllers/api/boards_controller.rb` — `import_obf`, `analyze_obz`,
  `download_obf`, and `parse_obf_import_options` (the license gate)
- `app/models/obz_importer.rb` — `.obz` package importer (`#import!`)
- `app/models/board.rb` — `Board.from_obf`, `find_or_create_image_for_button`
  (`is_private: true`), `attach_image_doc` (skipped unless `include_images`)
- `app/services/obz_analyzer.rb` — `.obz` inspection report
- `app/sidekiq/import_from_obf_job.rb` — async inline-JSON import
- `app/helpers/boards_helper.rb` — `to_obf` export serialization
- Specs: `spec/requests/api/boards/import_export_spec.rb`,
  `spec/models/obz_importer_spec.rb`

## Local Development in Docker

The DB and backend services can be run in Docker using `docker compose`.

To start the services, run the `bin/docker-dev` script.
This will open the console to a docker container that has Ruby, node, yarn installed.
From within the container
```
bin/dev
```
to start the Rails application.

If you notice the service immediately exit with:
```
15:03:28 redis.1   | exited with code 0
15:03:28 system    | sending SIGTERM to all processes
```
try running it again.

When finished, run `exit` in the Docker conatiner to close the shell.
This will then exit the Docker container and stop the Postgres and Redis containers.
