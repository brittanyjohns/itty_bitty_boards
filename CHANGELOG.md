# Changelog

All notable user-facing changes to this project will be documented here.
The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed — Menu board display image saved at full size

- A menu board's `display_image_url` was set to the 288×288 tile variant (`Doc#tile_url`) of the uploaded menu photo, so the menu looked blurry whenever it was shown at any meaningful size. It now stores the full-resolution image (`Doc#display_url`) — a menu has fine print and must stay legible on a full screen. Applies to both menu board creation and re-run.

### Added — `ai_credits` in admin user views

- `User#admin_api_view` and `User#admin_index_view` now include an `ai_credits` object (`CreditService.balance`: `plan`, `topup`, `total`, `reset_at`), so the admin user pages can display each user's AI credit balance.

### Changed — Menu boards are built from the image with AI vision

- Creating a "menu" board now sends the uploaded menu photo straight to an AI vision model (`MenuVisionService`, OpenAI Responses API) to extract the food and drink items. Previously the React app ran Tesseract.js OCR in the browser and sent the raw text; OCR on real-world menu photos (glare, angled shots, multi-column layouts) was unreliable, and the backend then stripped digits, punctuation, and line breaks before parsing — erasing the item boundaries the model needed.
- The menu form no longer runs in-browser OCR; it just uploads the image. The dead OCR text-parsing path (`OpenAiClient#clarify_image_description` / `#describe_menu` / `#strip_image_description`, `ImageHelper#clarify_image_description`, `Menu#describe_menu`) has been removed.
- New optional env var `MENU_VISION_MODEL` (default `gpt-4.1-mini`) selects the vision model.

### Fixed — Duplicate `SaveAudioJob` enqueued per board image

- `Board#add_image` enqueued `SaveAudioJob` twice for every image added to a board: once explicitly, and once via `BoardImage`'s `after_create :create_voice_audio_after_create` callback. Both jobs did the identical Polly audio lookup/creation and board-image update — wasted work and a mild race creating the same audio file concurrently. `add_image` now leaves audio generation entirely to the callback.

### Changed — MySpeak is now a free feature, the $3 MySpeak tier is retired

- The MySpeak ID (a demo communicator with a public profile, QR code, and emergency info) is now included on the **Free** plan. `FREE_DEMO_COMMUNICATOR_LIMIT` default is now `1` (was `0`), so every Free user can create one MySpeak demo communicator. That demo communicator is capped at one board (`ChildAccount::FREE_DEMO_BOARD_LIMIT`); Pro demo accounts keep the 3-board default.
- The `myspeak` / `myspeak_yearly` plan tier has been removed: dropped from `setup_limits`, Stripe checkout (`PLAN_PRICE_IDS`), `normalize_plan_key`, `BillingController` accepted plans, `CreditService::PLAN_MONTHLY_CREDITS`, `RefreshFreeTierCreditsJob`, and the Mailchimp tagging job. `User#myspeak?` is replaced by `User#has_myspeak_feature?` (true when the user has a demo-communicator slot).
- Run `bin/rails plans:migrate_myspeak_to_free` to move any existing `myspeak` / `myspeak_yearly` users onto the free plan (idempotent). Effective plan limits come from `config/application.yml` + host config, so `FREE_DEMO_COMMUNICATOR_LIMIT` must also be set there for the change to take effect outside CI.

### Fixed — Authenticated SMTP for production mail delivery

- Production mail now authenticates over SMTP when `SMTP_USERNAME`/`SMTP_PASSWORD` are set, instead of relying solely on `smtp-relay.gmail.com`'s IP-allowlist auth. The `mail:test` diagnostic showed production failing with `OpenSSL::SSL::SSLError: SSL_read: unexpected eof while reading` — the relay dropping unauthenticated connections from a non-allowlisted server IP, so every welcome email and team invite was silently failing.
- With credentials present, delivery uses authenticated `smtp.gmail.com` (IP-independent). With no credentials present, behavior is unchanged (the IP relay). `SMTP_ADDRESS` overrides the SMTP host — set it to `smtp-relay.gmail.com` to use the relay endpoint _with_ authentication.

### Fixed — Mail delivery diagnostics & production transport config

- Restored the explicit `config.action_mailer.delivery_method = :smtp` in `config/environments/production.rb` — it was dropped when the SMTP block was swapped to `smtp-relay.gmail.com`, leaving production reliant on the framework default. Documented the relay's IP-allowlist failure mode (delivery fails silently if the EC2/Hatchbox outbound IP is not registered in the Google Workspace SMTP relay console).
- Added `bin/rails 'mail:test[you@example.com]'`: prints the resolved ActionMailer config and attempts a real delivery, surfacing the actual SMTP error (credential failure, unallowlisted IP, connection refused) instead of letting it be swallowed by the `rescue` blocks in `User#send_welcome_email` and friends.

### Fixed — Demo account plan limits & legacy monthly-limit cleanup

- `MYSPEAK_DEMO_COMMUNICATOR_LIMIT` default changed from 1 to 0 and `PRO_DEMO_COMMUNICATOR_LIMIT` default from 10 to 1, so demo communicator accounts are granted to Pro only (1 account), matching the intended pricing model. `FREE` and `BASIC` were already 0.
- Removed the dead `API::ApplicationController#check_monthly_limit` helper — a legacy Redis-counter rate limit with no callers. AI features gate on `check_credits!` / `CreditService`. `MonthlyFeatureLimiter` and `User#monthly_limit_for` are intentionally kept: they still back the `can_use_ai?` / `ai_limit_reached?` path, whose cleanup is tracked separately.

### Changed — MySpeak quick-comm board now works on the Free tier

- `ChildAccount#favorite_boards` was plan-gated (`paid_plan?` / vendor), so a Free-tier user's MySpeak page showed an empty quick-comm board. Removed the gate — favorited boards now populate the MySpeak public page and `go_to_boards` for all tiers, including Free. Part of the MySpeak-goes-free rollout (itty_bitty_boards#142). MySpeak ID, profile, QR code, and safety/medical cards had no plan gate to begin with.

### Added — `core_boards:seed` rake task for public "Core + X" boards

- New `bin/rails core_boards:seed` task creates public, predefined boards modeled on the "Core + Lunch" board: an 8-column × 5-row, 40-tile grid with 20 fixed core words on the left half (black-bordered) and 20 topic words on the right half (borderless). Tiles are colored by part of speech via the modified Fitzgerald key.
- Topic words come from a curated list when the topic is known (`Lunch`, `Playground`, `Swimming`); otherwise they are AI-generated via `Board#get_words_for_scenario`. Controlled by env vars: `TOPICS="Playground,Swimming"`, `COUNT=n`, `AGE_RANGE`, and `DRY_RUN=1`.
- Reuses existing image artwork only — no image generation is queued, so the task incurs no image API cost. Words without artwork render as placeholders. Idempotent: boards that already have tiles are skipped.

### Added — Disable Audit Logging for communicator accounts

- Communicator (child) accounts now support a `settings["disable_audit_logging"]` flag, matching the existing flag on user accounts. When set, that communicator's word clicks are not recorded as `WordEvent` records. Toggled from the communicator account form.
- `API::Audits#word_click` and `#public_word_click` now skip `WordEvent.create` when the acting user or the communicator account has audit logging disabled (new `User#audit_logging_disabled?` / `ChildAccount#audit_logging_disabled?` helpers). Previously the user-level flag was honored only by the frontend; it is now enforced server-side as well.

### Added — Range-aware communicator stats endpoint

- New `GET /api/word_events/stats?account_id=X&days=N` (`API::Audits#communicator_stats`) returns a single bundled, range-filtered stats payload for a communicator account's Stats tab: `range`, `summary` (total events, unique words, active days, most active day, average per active day, top word), `heat_map`, `most_clicked_words`, `part_of_speech_breakdown`, and the word `events` list (capped at 500). `days` accepts 30/60/90/180/365 and falls back to 180 for any other value. Previously the Stats tab pulled an all-time `heat_map` and a fixed 7-day `most_clicked_words` from `child_accounts#show`, so its day-range selector had no effect on the data.
- `WordEventsHelper#heat_map` now takes an optional range argument; added `WordEventsHelper#word_events_summary(range)` and `#part_of_speech_breakdown(range)`. Existing no-arg `heat_map` callers are unchanged.

### Added — Communication Prompt Mode for caregivers

- New `CoachingPromptSet` model + `API::CoachingPrompts` controller (`GET/POST/PATCH/DELETE /api/coaching_prompts`). A caregiver opens a board in Caregiver Mode and the API returns a coaching prompt set with strategies + tappable example phrases. Curated SpeakAnyWay sets ship for Snack Time, Car Ride, Bedtime Story (matched against `Board#tags` / name tokens). For boards without a curated match, `CoachingPromptGenerator` calls OpenAI (`gpt-4o-mini`) once and caches the result on the board's `metadata` jsonb so the second visit costs nothing. Staging skips the paid call and returns the bundled fallback set, mirroring the existing OpenAI image staging stub.
- Users can create / edit / delete their own custom coaching sets via the same endpoint — owned sets are scoped by `user_id`. Editing SpeakAnyWay-shipped or another user's sets returns 403.
- New `users.settings["is_caregiver"]` flag — opt-in preference lives in the existing user settings jsonb (same pattern as `wait_to_speak`, `show_labels`, etc.). Flipped via the existing `POST /api/users/:id/update_settings` endpoint, exposed in the Settings page UI.
- Free for everyone — no `CreditService` gating. Cost is bounded by per-board caching of AI fallback generations.
- **Audio cache**: `GET /api/coaching_prompts/audio?text=...&voice=...&language=...` returns a stable mp3 URL for a coaching phrase + voice tuple. Backed by a new `CoachingPhraseAudio` model with an ActiveStorage attachment, keyed on `sha256(version|text|voice|language)`. First call synthesizes via the existing `VoiceService` (Polly / OpenAI) and uploads to S3; every subsequent caller for the same tuple — across the whole app — gets the same URL without hitting TTS. Race-safe via a unique-index `phrase_key` column. Skips synthesis in `Rails.env.test?` unless `ENV["ALLOW_COACHING_AUDIO_TTS"]` is set.

### Fixed — Pro users showing 0 AI credits ("granted and expired same day")

- `CreditService.grant_plan!` now clamps `period_end` to a minimum of
  `Time.current + 1.day` (`CreditService::MIN_GRANT_WINDOW`). A bad
  upstream value (stale `plan_expires_at`, `trial_end == 0`, etc.) was
  causing the new `plan_grant` row to land already-expired, and the
  hourly `ExpirePlanCreditsJob` would sweep it to 0 within the hour.
  Issue #110 patched the rake task; this patches the service so no
  caller can reintroduce it. A `Rails.logger.warn` fires on every clamp
  so we can find any upstream caller still writing bad dates.

### Changed — Free tier is now 5 AI credits/month (was 10)

- `PLAN_MONTHLY_CREDITS["free"]` lowered from 10 to 5. Applies to
  signup grants, the daily refresh job, and post-cancellation grants.

### Changed — Canceled/paused subscriptions keep 5 free credits (was 0)

- `customer.subscription.deleted` and `customer.subscription.paused`
  webhooks previously called `CreditService.expire_plan_credits!`,
  leaving the user at 0 until the next daily refresh. Now they call
  `CreditService.grant_plan!` with the free-tier allowance, so users
  land on free with 5 credits immediately. The prior balance is still
  expired (ledger trace preserved); top-ups are still untouched.

### Changed — Monthly credit refresh now covers non-Stripe paying users

- `RefreshFreeTierCreditsJob` (daily, 3am UTC) used to refresh only
  `free` and `basic_trial` users. It now also refreshes any user
  without a `stripe_subscription_id` — App Store / RevenueCat
  subscribers, admin/demo accounts on paid tiers — granting their
  actual plan_type's allowance (Pro = 1500, Basic = 400, etc.).
  Stripe-driven paying users continue to be refreshed by
  `invoice.payment_succeeded`. Class name unchanged for cron stability.

### Added — AI word suggestions adapt to the communicator

- Board generation now accepts an optional communicator profile — `age` / `age_band`,
  `aac_level` (`emerging` / `developing` / `proficient`), and `vocab_type` (`core` /
  `fringe` / `balanced`) — on the AI word-suggestion endpoints (`GET /api/boards/words`,
  `POST /api/boards/:id/additional_words`) and the scenario board create flow. For young
  or emerging communicators the prompt now leans on core vocabulary, verbs, and emotions
  instead of clinically literate adult nouns. All fields are optional; callers that send
  no profile get the same output as before. Normalization lives in the new
  `CommunicatorProfile` service object.

### Fixed — Private boards no longer viewable by anyone with the link

- `GET /api/boards/:id` (which backs the frontend `/pb/<slug>` route) is unauthenticated
  and previously rendered any board regardless of ownership or publish state — a
  logged-out visitor could view a private board with just its slug. It now returns a
  generic 404 unless the board is published, or the requester is the owner, an admin, or
  a member of a team the board is shared with (`Board#viewable_by?`).

### Changed — Staging no longer makes paid OpenAI image calls

- When `ENV["STAGING"] == "true"`, all OpenAI image operations (generation, variations, edits) are stubbed with the bundled `public/placeholder.jpeg` instead of hitting the paid API. The rest of the image pipeline (Doc creation, ActiveStorage attachment, board tiles, status transitions) runs normally, so staging can be exercised end-to-end without spending money. Production behavior is unchanged. Gated via the new `AppEnv.staging?` helper.

### Fixed — AI credits now actually grant on signup and refresh for free users

- **Signup grant.** New users land in `basic_trial` for 14 days (via `User#set_soft_trial_plan`) but the after-create flow never granted them any credits, so every AI call returned `402 insufficient_credits`. Added `User#grant_initial_plan_credits` (after_create) → `CreditService.ensure_initial_grant!(user)` which writes a `plan_grant` row sized to the tier (`basic_trial` = 400, matching Basic; `free` = 10; etc.) with `expires_at` of 14 days for trial users and 30 days for everyone else.
- **`basic_trial` plan_type was missing from `CreditService::PLAN_MONTHLY_CREDITS`** — it fell back to free (10 credits) instead of the intended Basic-equivalent (400). Fixed.
- **Soft-trial downgrade now grants free credits.** `DowngradeSoftTrialJob` (daily at 2am UTC) flips expired trial users to `free`; now also calls `CreditService.grant_plan!` for 10 credits with a 30-day expiry so they don't see balance=0 the moment they're downgraded.
- **Monthly refresh for non-subscription tiers.** New `RefreshFreeTierCreditsJob` runs daily at 3am UTC and re-grants the tier allowance to users on `free` / `basic_trial` whose `plan_credits_reset_at` has passed. Paid Stripe subscribers (MySpeak, Basic, Pro, Partner Pro) continue to be refreshed by `invoice.payment_succeeded`; the new job is just for users without a Stripe billing cycle.

### Added — Phase 4 of usage-based AI pricing (renewals + auto-grant)

- `invoice.payment_succeeded` webhook handler — fires on initial paid period and every renewal. Reads `monthly_credits` and `plan_type` from the subscription line's Price metadata (falls back to `CreditService::PLAN_MONTHLY_CREDITS`), then calls `CreditService.grant_plan!` with `period_end = subscription.current_period_end`. Idempotent on Stripe event id, so retried webhooks never double-credit.
- `customer.subscription.created` (status `trialing`) now grants trial credits with `period_end = subscription.trial_end`. Paid subscriptions still get their credits via the invoice path.
- `customer.subscription.deleted` / `.paused` now expire plan credits via `CreditService.expire_plan_credits!`. Top-up credits are preserved.
- `ExpirePlanCreditsJob` runs hourly as a backstop — zeroes out plan credits whose `plan_credits_reset_at` has passed and no webhook arrived to refresh them.
- **Fix:** `apply_free_plan` previously referenced `FREE_PLAN_LIMITS` unqualified in the controller, which raised `NameError` silently swallowed by the `rescue` — so cancellations never actually downgraded users. Now resolves `User::FREE_PLAN_LIMITS` correctly.

### Changed — Phase 3 of usage-based AI pricing (enforcement switched)

- **AI features now spend credits at request time.** The Redis monthly counter (`MonthlyFeatureLimiter`) is no longer in the AI hot path — `CreditService.spend!` is the source of truth.
- New API gating helper `check_credits!(feature_key:, feature_name:, amount: nil)` in `API::ApplicationController`. Admins bypass the check.
- AI endpoints now return **HTTP 402 `insufficient_credits`** with `{ feature, needed, balance, plan_credits, topup_credits, reset_at, topup_url }` when the balance is too low. HTTP 429 is reserved for true rate limiting and is no longer used by AI gating.
- All 10 AI controller callsites now charge weighted credits per their real feature (image_generation=5, image_edit=3, scenario_create=10, etc.) instead of a flat `ai_action=1`.
- Shadow-mode telemetry from Phase 1 has been removed. `check_monthly_limit` remains in the codebase as a generic Redis-counter helper but is no longer wired to AI endpoints.

### Added — Phase 2 of usage-based AI pricing

- `POST /api/stripe/checkout_sessions/topup` — creates a one-time Stripe Checkout Session for a credit pack (`pack_key`: `small` / `medium` / `large`, optional `quantity`).
- Stripe webhook now branches on `metadata.kind == "topup"` for `checkout.session.completed`. Top-up sessions call `CreditService.grant_topup!`, idempotent on the Stripe event id.
- Webhook falls back to expanding `line_items.data.price.metadata.credit_amount` when the session metadata is missing — keeps the system working even if the frontend was on an older build that didn't pass `credit_amount` through.
- New env vars: `STRIPE_PRICE_TOPUP_SMALL`, `STRIPE_PRICE_TOPUP_MEDIUM`, `STRIPE_PRICE_TOPUP_LARGE` (Stripe Price IDs for the three pack sizes).

### Added — Phase 1 of usage-based AI pricing

- AI credit ledger (`credit_transactions` table) — immutable record of every grant, spend, expire, and refund of AI credits.
- `users.plan_credits_balance`, `users.topup_credits_balance`, `users.plan_credits_reset_at` columns — denormalized balances and current-period end.
- `CreditService` — single entry point for credit operations (`spend!`, `grant_plan!`, `grant_topup!`, `expire_plan_credits!`, `refund!`, `shadow_spend`). Spends drain plan credits first, then top-up.
- `CreditService::FEATURE_COSTS` — weighted costs per AI feature (image generation = 5, scenario builder = 10, word suggestion = 1, etc.). Server-authoritative.
- `GET /api/me/credits` — returns `{ plan, topup, total, reset_at, plan_type }` for the current user.
- `GET /api/me/credit_transactions` — paginated transaction ledger for the current user.
- `bin/rails credits:backfill` — gives every existing user an initial plan-credit grant based on their `plan_type`. Idempotent.
- `bin/rails credits:recompute_balances` — rebuilds denormalized balances from the ledger.
- Shadow-mode telemetry — `check_monthly_limit` in the API base controller now also runs `CreditService.shadow_spend` and logs divergences between the Redis-counter decision and the credit-ledger decision. **No user-visible change yet** — the Redis limiter remains the source of truth in Phase 1.

### Coming next

- **Phase 5 (optional):** Stripe Meter-based overage billing.
