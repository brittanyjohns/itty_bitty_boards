# Safety profiles (MySpeak) — view alerts + random slugs

> Extracted from CLAUDE.md on 2026-07-11 (hub-and-spoke restructure).
> This file is the authoritative doc for this subsystem — update it (not CLAUDE.md)
> when behavior changes. CLAUDE.md keeps only the cross-cutting invariants.

## Spoken intro / bio audio

`SaveProfileAudioJob` → `Profile#update_audio(:intro | :bio)` pre-renders each
field to an mp3 through Polly and attaches it (`intro_audio` / `bio_audio`),
which is what `safety_view` publishes as `intro_audio_url` / `bio_audio_url`.

**Each field is gated on its own text, never on `intro`.** The guard used to be
`return unless intro.present?` at the top of the method — above the branch that
picks which field it is rendering — so a profile with an About me and no intro
got neither clip. This is a latency bug, not a missing-feature one: when a clip
is absent the public page falls back to synthesizing on **every tap**
(`POST /api/images/generate_audio`, measured 0.5s warm and 3.8s cold), so
"Hear me" / "Read aloud" sit silent for seconds each time they are pressed.
Anything that stops a clip being pre-generated has that cost.

`enqueue_audio_job_if_needed` already tracks the two fields independently
(`saved_change_to_bio? || (bio.present? && !bio_audio.attached?)`), so a
profile that was skipped under the old guard re-enqueues on its next save.

## Safety-profile view alerts (issue #384)

Public safety (MySpeak) pages have two surfaces. The **open page**
(`GET /api/profiles/public/:slug`) is the everyday "social" surface — name,
avatar, intro, bio, public boards, QR, plus the page-safe settings
(`Profile::SAFETY_PAGE_KEYS` = `pronouns`, `device_notes`). The **emergency
info** — medical details + emergency contacts + emergency notes
(`Profile::SAFETY_SENSITIVE_KEYS`) — is sensitive and lives behind a wall.

- **Sensitive data is withheld from page-open.** `Profile#safety_view` only
  serializes `SAFETY_PAGE_KEYS` and adds a boolean `has_safety_info` so the
  frontend can show the "Emergency Info" button without shipping the data.
  `GET public` therefore carries **no** medical info or contacts — the wall is
  real, not just a UI modal.
- **The public page serializes boards as CARDS, never `api_view`.** `#public`
  is unauthenticated, so **all three** board lists in the payload go through
  card-sized serializers, with no exceptions left:
  | payload key | serializer | page |
  |---|---|---|
  | `general_public_boards` | `Board#public_card_view` | both |
  | `public_boards` | `ChildBoard#public_card_view` | MySpeak (`/my/:slug`) |
  | `user_boards` | `Board#public_page_card_view` | User page (`/u/:slug`) |

  The full `api_view` on either model publishes identities — `Board#api_view`
  carries `in_use_by` (a joined list of every communicator NAME using the
  board) plus `communicator_account_data` (their account ids, names, avatar
  URLs), and `ChildBoard#api_view` carries `added_by`, the EMAIL of whoever
  assigned the board. On a User's own public page `in_use_by` is that user's
  OWN communicators' names, which is exactly the thing a public page must not
  hand out. The frontend gates all of it behind `!isPublicGrid && can_edit`,
  so none of it was ever rendered publicly — it was only ever transmitted,
  which is the whole failure mode: a field nobody sees is a field nobody
  notices leaving. `public_page_card_view` is the wider of the two Board
  cards (it adds `predefined` / `published` / `user_id` and pins `can_edit`,
  `locked`, `in_a_public_group` to false) because the User page's grids
  (`BoardGrid` / `BoardGridItem` / `PublicFeaturedBoards`) read more than the
  MySpeak grid does. `Profile#api_view` — the AUTHENTICATED view behind
  `GET /api/profiles/:id`, which the edit form uses — keeps `api_view` for
  `user_boards`; only the public payloads are carded. Adding a field to a
  public card is a decision about what the whole internet sees.
- **`general_public_boards` is the whole admin library, so it is cached, not
  per-request.** `Board.public_board_cards` memoizes into `Rails.cache` (Redis
  in prod) keyed on `Board.public_board_cards_cache_key` (count + max
  `updated_at`). That key is also folded into `profile_public_etag`, because
  the library rides along in the body and would otherwise be unable to
  invalidate a 304. Serializing it inline with `api_view` is what made this
  endpoint take 11.5s in production (of which ~10.3s was Ruby, not SQL).
- **The gated reveal records + alerts.** `POST /api/profiles/public/:slug/safety_view`
  (`API::ProfilesController#safety_view`, unauthenticated) is the deliberate
  "open emergency info" action. It (a) returns the sensitive payload
  (`Profile#safety_details_view` = `{ id, settings: <SAFETY_SENSITIVE_KEYS> }`)
  and (b) enqueues the view-log / parent-alert job. **Page-open no longer
  enqueues anything** — `#public` just serves the social page. Safety profiles
  only (`profile.safety?`); 404 for non-safety/unknown slugs; an unclaimed
  placeholder reveals nothing and records nothing. The enqueue is wrapped in a
  rescue so a Redis hiccup can't 500 the reveal — the sensitive data still
  renders.
- **Capture is fire-and-forget.** `#safety_view` calls `log_safety_profile_view`,
  which enqueues `RecordProfileViewJob.perform_async(profile.id,
  request.remote_ip, request.user_agent)`, rescuing broadly.
- **`RecordProfileViewJob`** (`app/sidekiq/`) does all the heavy/failable work
  off-request:
  1. Always logs the raw view (IP + user agent + timestamp) to the
     **`profile_views`** table (`ProfileView` model) — the audit history that
     makes unexpected access patterns visible.
  2. Sends the parent alert only when: the communicator has an owner
     (`Profile#alert_recipient` → `child_account.owner`), the per-profile
     opt-out is off (`Profile#view_alerts_enabled?`, default **true**), the
     owner hasn't set the global `settings["disable_notifications"]`, and the
     **per-profile hourly throttle** is claimed (atomic Redis `SET NX EX`, key
     `safety_view_notify:<profile_id>`, mirroring `DiskSpaceAlertJob`). Window is
     ENV-tunable via `SAFETY_VIEW_THROTTLE_SECONDS` (default 3600).
  3. **Geolocation runs only after the throttle is claimed** — so the external
     IP lookup happens at most once per profile per hour, not on every bot/scan.
     Only the notified view row gets `approx_location`/`geo`; throttled views are
     logged without location.
- **Channels:** `Notifications::SafetyViewNotifier` is the channel-dispatch
  seam. v1 = email (`SafetyProfileMailer#viewed_alert`, i18n under
  `safety_profile_mailer.viewed_alert` in `config/locales/mailer.{en,es}.yml`).
  A **push channel is stubbed** (`deliver_push` / `push_enabled? == false`) so it
  drops in once device-token registration + FCM/APNS exist — there is **no push
  infrastructure today**.
- **Coarse IP→location** is `IpGeolocation.coarse(ip)` (`app/services/`), a total
  wrapper over the **`geocoder`** gem that returns a city-level
  `{ city, region, country, label }` or **nil** on any error / private IP /
  missing result (the email just omits location). Provider is ENV-tunable in
  `config/initializers/geocoder.rb`: `GEOCODER_IP_LOOKUP` (default `ipinfo_io`),
  `IPINFO_API_KEY`, `GEOCODER_TIMEOUT`.
- **Opt-out is frontend-free:** `view_alerts_enabled` rides the existing
  `settings: {}` param on `PATCH /api/profiles/:id` and is exposed on the
  authenticated `Profile#api_view`, so a toggle needs no new endpoint.
- **Note on `should_receive_notifications?`:** intentionally **not** reused here
  — it bundles an unrelated cross-feature 2-hour throttle that would wrongly
  swallow a safety alert. The per-profile hourly throttle is the only timing gate.


## Care sections — the second gated reveal

`settings["care"]` holds optional, structured "how to support this person day to
day" sections: Communication, Personal Care, Meals, Sensory, Mobility,
Transportation, plus up to `MAX_CUSTOM_CARE_SECTIONS` parent-authored custom
sections. They are mostly multiple-choice and short-answer, deliberately unlike
the free-text bio.

- **They are a third privacy tier, not a variant of the other two.** Not in
  `SAFETY_PAGE_KEYS` (never open on page-load) and not in
  `SAFETY_SENSITIVE_KEYS` (not an emergency). `POST
  /api/profiles/public/:slug/care_view` is the only path that serves them, and
  `safety_view`'s `has_care_info` flag is what lets the page render the button
  without the data — the same fail-closed shape as `has_safety_info`.
- **The care reveal logs but never alerts.** `log_care_profile_view` enqueues
  `RecordProfileViewJob` with `kind: "care"`; the job writes a `ProfileView` with
  `view_kind: "care"` and returns before the throttle claim, the geolocation
  lookup, and `Notifications::SafetyViewNotifier`. This is the whole reason for a
  separate endpoint. A substitute teacher checking a snack rule is routine; if
  that fired the emergency-view email, parents would learn to ignore the alert
  that actually matters. A care reveal also does **not** consume the hourly
  notify slot, so a real emergency reveal moments later still alerts.
- **`Profile::CARE_SECTIONS` is the whole schema.** Each field is
  `:multi_select` or `:short_text` with its option list. `:single_select` is
  still supported by the sanitizer and the editor but **no field uses it** —
  see the two shape rules below. `sanitize_care_settings` (a `before_save`, modelled on
  `sanitize_theme_settings`) is the only thing between a request body and an
  unauthenticated page, because `profile_params` permits `settings: {}`
  wholesale. It whitelists sections/fields/options, enforces the custom-key
  format `CARE_CUSTOM_KEY_FORMAT` and every length/count cap, strips markup, and
  **drops rather than rejects** — a stale frontend must not be able to 422 a
  parent out of saving. If nothing survives, the key is deleted so
  `has_care_info?` stays honest.
- **The registry is SERVED, not duplicated** — `GET /api/care_sections`
  (`API::CareSectionsController`, unauthenticated like `preset_colors`; it is a
  static schema with no user data in it). `Profile.care_registry_view` emits the
  sections in registry order, every field's type, its options where it has them,
  every cap the sanitizer enforces, and `CARE_CUSTOM_KEY_FORMAT` translated to
  JavaScript anchors (Ruby's `\A`/`\z` don't compile in a JS RegExp).
  `src/data/careSections.ts` keeps a bundled copy only as an offline/first-paint
  fallback. **This is why editing CARE_SECTIONS is now safe to do alone** — the
  frontend previously carried a hand-copied duplicate, and since
  `sanitize_care_settings` DROPS an unrecognized key rather than rejecting it, a
  rename deleted that answer from every profile with no error and no 422.
- **The LABELS are served too, and the backend owns them.** `CareLabels`
  (`app/services/care_labels.rb`) resolves a section / field / option key
  against `config/locales/care.{en,es}.yml`; `care_registry_view` emits them as
  `label` on each section and field plus an `option_labels` hash on each select
  field. Ported verbatim from the frontend locale files, which were the only
  place they existed — meaning nothing server-side could render care data for a
  human, and a printed sheet can't say "Braces or afos".
  - **Labels are ADDITIVE and must stay that way.** `options` stays an array of
    plain strings because the deployed frontend parses it with `asStringList`,
    which returns `[]` for objects — promoting options to `{key, label}` would
    empty every section in the live editor. New information goes in sibling
    keys, never by changing the shape of an existing one.
  - **`option_labels` is deliberately wider than `options`:** offered ∪ retired
    (`accepted_care_options`). A retired option is still stored on real profiles
    and still has to render; it just must never be offered.
  - The fallback is a hand-written `CareLabels.humanize`, not `String#humanize`
    — the latter strips a trailing `_id` and consults inflections, so Ruby and
    TypeScript could disagree on exactly the unlabeled keys where the fallback
    is the only thing running.
  - `spec/services/care_labels_spec.rb` fails the build if any section, field,
    or accepted option lacks a label. It reads the raw `I18n.backend`
    translation store rather than `I18n.exists?`/`I18n.t`, both of which follow
    `config.i18n.fallbacks` — `I18n.exists?("care.sections.mobility", :fr)` is
    **true** purely because `:fr` falls back to `:en`, which would make the
    whole sweep a test that English exists. An anti-vacuity example asserts a
    care-label-less locale still reports missing.
  - The payload is locale-dependent, so `GET /api/care_sections` is
    `expires_in 1.hour, public: false` — a shared cache keyed on the path alone
    would hand a Spanish registry to an English client. `?locale=` is
    whitelisted against `I18n.available_locales`, never symbolized from raw
    params.
- **Retiring an option is a TWO-STEP process, and step one is one line.**
  `Profile::DEPRECATED_CARE_OPTIONS` maps
  `section => field => { retired_key => replacement_or_nil }`. Adding a key
  there makes `care_registry_view` stop OFFERING it while
  `sanitize_care_settings` keeps ACCEPTING it — so nobody picks it fresh and
  nobody loses what they already wrote. Then `rake care:audit_options` reports
  who still holds one and `rake care:remap_options` (dry-run by default,
  `DRY_RUN=false` to apply, `PROFILE_ID=n` to scope) moves them onto their
  replacements via `CareOptionRemap` (`app/services/`). Only once the audit
  reports zero is it safe to delete the key from `CARE_SECTIONS` and from
  `DEPRECATED_CARE_OPTIONS`. **Do not skip to the delete** — see below.
  A rename is a remove plus an add: deprecate the old key, add the new one, map
  old => new.
- **Removing an option WITHOUT deprecating it still deletes stored data.**
  `sanitize_care_settings` is a `before_save`, not a check on the incoming
  payload, so it re-cleans the whole blob on *every* profile save — an avatar
  upload is enough. Retiring an option therefore needs a backfill first, or a
  deprecation window where the key stays in the constant (accepted by the
  sanitizer, hidden from the editor) until the data is migrated. Tracked in
  itty-bitty-frontend#679.
- **`DEPRECATED_CARE_OPTIONS` is empty, and that is not evidence nothing was
  ever cut.** The reshape that dropped `echolalia`, the help-level scales, the
  response-time field, and the per-section `notes` fields deleted them outright
  from `CARE_SECTIONS`, because it landed **before the feature was announced**,
  when no profile held a single care answer and there was nothing to protect.
  That was a one-time licence and it has expired — every later change goes back
  through the two steps above. Check before assuming otherwise: a care-data
  count on the production console is the whole verification.
- **Two shape rules govern every field, and `care_preset_reshape_spec.rb`
  enforces them.** (1) Presets are **multi-select** — a single-select makes a
  parent pick the one truest thing about someone whose support is layered
  (independent at home, hand-over-hand at school), and a half-true chip on a
  card a substitute reads is worse than no chip. This is also why the
  "independent / some help / full help" scales are gone: they rated a person
  where a helper needed something to *do*. (2) Option lists stay **short** —
  six is the ceiling, and the one deliberate exception
  (`communication.methods`) is named in the spec with its reason, so an
  exception stays visible instead of becoming the norm.
- **Built-in sections carry `items`, and they are the ONLY free-text surface.**
  The same label/value rows as a custom section, same caps, same
  `clean_care_items`. The presets answer "which of these applies"; the specific,
  provisional detail a parent needs to hand on ("Bus: back left seat, by the
  window") doesn't compress into a chip. There is deliberately **no
  per-section `notes` field** — it sat next to the detail lines asking the same
  question, so parents split one answer across two boxes. Short option lists are
  only lossless *because* the lines are there. A built-in section survives on
  lines alone, so `clean_builtin_care_section` returns nil only when values AND
  items are empty. The key is omitted rather than stored as `[]`, and a row
  written before this shipped round-trips unchanged.
- **Care fields are never eligible for writing suggestions** — same rule as
  `SAFETY_SENSITIVE_KEYS`. Nothing here goes to OpenAI.
- Care info is deliberately **not** on the Safety ID card or device tag; those
  are emergency artifacts. The **care plan PDF** is the artifact that carries
  it — see below.

## The care plan PDFs

`Communicators::GenerateCarePlan` builds two owner-downloadable documents from
the same data the two gated reveals serve:

| variant | attachment | contents |
|---|---|---|
| `:full` | `care_emergency_plan_pdf` | care sections **+** emergency info |
| `:care_only` | `care_plan_pdf` | care sections only |

`POST /api/profiles/:id/care_plan?variant=` — one route, variant as a param,
behind the controller-wide owner gate. **Nothing is added to the public MySpeak
page**: the page keeps its two gated reveals and gains no download button, so
this introduces no new path to emergency data.

Things that will bite a future change:

- **A flowing document is not a card, and the two render paths are different
  on purpose.** `BaseAssetGenerator#generate_pdf_from_html` pins Grover to a
  fixed pixel page — right for the 1200×1800 safety card, and silently
  destructive here, because a care plan is however many pages the parent's
  answers come to and everything past the fixed height is discarded.
  `GenerateCarePlan#generate_letter_pdf` is the flowing counterpart
  (`Marketing::SheetRendering::LETTER_GROVER_OPTIONS`). Reaching for the wrong
  one is the failure this pair exists to make obvious.
- **`@page { margin: 0 }` would silently delete the page numbers.** Chrome
  renders header and footer in a SEPARATE document that inherits none of the
  page's CSS and is clipped to nothing unless the page reserves margin for it.
  `layouts/pdf_printable.html.erb` has exactly that rule, so copying its
  `@page` block is the obvious wrong move; `layouts/pdf_care_plan.html.erb`
  deliberately declares only `size`. An explicit (empty) `header_template` is
  equally required or Chrome prints its own title-and-date header. Pinned in
  `generate_care_plan_spec.rb` rather than left to a visual check.
- **PDF only, no PNG.** A PNG of a multi-page document is either one
  impossibly tall image or a silently cropped first page, and nothing displays
  it.
- **Not in `Profile#generate_attachments!`.** That runs synchronously on every
  safety-profile save — an avatar upload, a theme tweak — and is already four
  Grover renders. These generate on demand from the endpoint; the freshness
  signature makes a repeat download free.
- **The freshness signature carries the variant AND a `LAYOUT_VERSION`.**
  `safety_info_signature` only moves when the PROFILE changes, so without the
  version constant a template redesign leaves every cached PDF stale forever —
  a gap the card generators still have. Bump `LAYOUT_VERSION` when the template
  or layout changes in a way existing documents should pick up.
- **Section-level `break-inside: avoid` is the wrong instinct.** A built-in
  section can carry four fields plus eight detail lines, which exceeds a page,
  and an unbreakable box taller than a page makes Chrome push the whole thing
  over and leave a dead half-page. The mechanism is a `.section-keep` wrapper
  holding the heading plus its first row; everything after that flows. The
  "Day-to-day support" divider lives INSIDE the first section's keep block for
  the same reason — rendered above the loop it stranded at the foot of page 1
  with the first section overleaf, which only a real render showed.
- **An empty plan is refused, not printed.** `GenerateCarePlan.printable?` is
  checked in the controller (a service that raises can't answer 422):
  `care_only` with no care info → `no_care_info`; `full` with neither → 
  `nothing_to_print`. `full` on emergency info alone still prints — that's the
  hospital-bag case. Blank emergency FIELDS are printed as "None listed"
  rather than omitted, matching the safety ID card: a missing Medications
  heading and "Medications — none listed" read very differently to a nurse.
- **`Communicators::CarePlanDocument` is a port of `resolveCareSections`**
  (frontend `src/data/careSections.ts`). The labels are not duplicated —
  `CareLabels` serves those — but the walk over stored settings genuinely
  exists twice, because one renders server-side and one client-side. Change
  both.


## Generating the printables is owner-only

`API::Profiles::AssetsController` (`POST /api/profiles/:id/safety_id`,
`/device_tag`) gates on `ChildAccount#editable_by?` — owner or admin, the same
rule as `API::ProfilesController#update`. Deliberately **not** team-wide: an
SLP supervisor can be on the team and still not mint these.

The gate is load-bearing because the actions return
`Profile#url_for_attachment`, which is an **unsigned `CDN_HOST + key` URL**, not
a signed or expiring one. Serving one for a profile the caller doesn't own
publishes that communicator's allergies, medications and ICE contacts
permanently, to anyone the link reaches. Sequential ids are not a defense. The
controller authenticated but never authorized until this was fixed; the guard
is a `before_action` so a non-owner can't even trigger a `regenerate`.

Fail-closed in two places worth keeping: an unrecognized `profileable_type`
is refused rather than allowed, and `profileable` is `optional: true`, so an
orphaned profile safe-navigates to nil and 403s instead of raising.

## About Me (public bio) vs emergency notes (private)

The MySpeak page has two distinct free-text fields that were historically
conflated:

- **About Me = `profiles.bio`** (a text column) — the PUBLIC blurb shown on the
  open page. Editable via `PATCH /api/profiles/:id` (`profile_params` already
  permits `:bio`).
- **Emergency notes = `settings["emergency_notes"]`** — one of the
  `SAFETY_SENSITIVE_KEYS`, withheld from page-open and revealed only by the
  gated `safety_view` POST. Also printed on the Safety ID card.

**Onboarding writes them separately** (`API::V1::Onboarding::MyspeakController`):
`about_me` → `bio`, `emergency_notes` → `settings["emergency_notes"]`.
Previously the wizard sent a single `care_notes` field that was written into
`bio`, publishing safety text on the open page. **Legacy compatibility:** a
request that sends only `care_notes` (an old frontend still deployed) routes
that text to the PRIVATE `emergency_notes`, never the public bio — privacy wins
during the deploy gap. When no `about_me` is sent, `bio` is left blank so
`Profile#set_defaults` fills the placeholder rather than leaking notes.

**One-time cleanup:** `rake profiles:copy_onboarding_bio_to_emergency_notes`
(dry-run by default, `DRY_RUN=false` to apply, `USER_ID=N` to scope) copies
existing onboarding bios into blank `emergency_notes` for child-account safety
profiles, keeping the bio (no public page goes blank). Skips generated
placeholder bios and profiles that already have emergency notes; idempotent.

## Random slugs for safety profiles

Safety profiles (`profile_kind = "safety"`, i.e. a `Profile` whose
`profileable` is a `ChildAccount`) get an **unguessable random slug** instead
of a name-derived one, so a child's public emergency page (`/my/<slug>`) can't
be found by guessing their name. Vendor/SLP/user pages keep readable slugs.

- **Format:** `s-` + 6 chars from `Profile::RANDOM_SLUG_CHARS` (lowercase
  alphanumerics minus the ambiguous `0 o 1 l i`), e.g. `s-k8x2mf`. Generated by
  `Profile.generate_random_slug` (retries on collision against both `slug` and
  `legacy_slug`). Already valid under the existing `SLUG_FORMAT`.
- **When it's applied:** `Profile#ensure_slug` (a `before_validation … on:
  :create`) only fills a **blank** slug. For a safety profile it generates a
  random slug and sets `slug_type = "random"`; otherwise it falls back to
  `username.parameterize` (`slug_type` stays `"legacy"`).
- **MySpeak onboarding always gets a random slug.**
  `API::V1::Onboarding::MyspeakController#create` derives a readable, unique
  **username** from the name (`unique_slug_for`) but leaves the profile **slug
  blank** so `ensure_slug` assigns the random one — and **ignores any
  client-supplied `slug`** (random is non-negotiable for safety pages; the
  wizard no longer collects a link). The username stays human-readable because
  it's the handle shown on the page a responder already scanned, not the public
  URL. `ChildAccount#create_profile!` (programmatic communicator creation, not
  the wizard) still passes a name-derived slug — its new profiles are caught by
  the backfill task but it does **not** yet auto-randomize on create (follow-up).
- **Not user-editable:** `Profile#slug_editable?` returns `false` when
  `slug_type == "random"`, regardless of the 7-day edit window. `slug_type` and
  `slug_editable` are exposed on `Profile#api_view`.
- **Legacy fallback:** the migration preserves the old slug in
  `profiles.legacy_slug` (conditional unique index, NULLs allowed).
  `API::ProfilesController#public` falls back to `legacy_slug` and
  **301-redirects** to the current slug, so printed cards / bookmarks keep
  working. `Profile.slug_available?` also checks `legacy_slug` so a freed-up old
  slug can't be re-squatted.
- **Backfill + cards:** `rake profiles:migrate_to_random_slugs` is **dry-run by
  default** (reports what would change, enqueues nothing); apply with
  `DRY_RUN=false`, scope with `USER_ID=N`. When applied it migrates every
  matching `slug_type = "legacy"` safety profile (via `update_columns`, skipping
  validations/callbacks) and enqueues `RegenerateSafetyCardsJob` for **only the
  profiles migrated in that run** (so a re-run / scoped run doesn't re-email
  parents whose cards are current).
  That job re-renders the safety ID card + device tag with the new QR target
  (`Communicators::GenerateSafetyIdCard`/`GenerateDeviceTag` with
  `regenerate: true`) and emails the parent via
  `CommunicationAccountMailer#safety_cards_updated`. Run after deploy so the
  legacy fallback is live before slugs change.

