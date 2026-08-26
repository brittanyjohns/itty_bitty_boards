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
- **Every board list in a public payload is filtered on `published`.** The
  grid selects on `child_boards.favorite`, but the board BEHIND each card is
  gated on `Board#viewable_by?`, which refuses an anonymous visitor an
  unpublished board — so an unfiltered list served a working card (name, slug,
  cover) for a private board and then 404'd whoever tapped it. Both
  `Profile#communication_boards` (**both** of its polymorphic branches) and
  `Profile#user_boards` carry the filter; `general_public_boards` already had
  it via `Board.public_boards`. This is the READ half of the invariant — the
  write half is `Boards::MySpeakPublisher`, which publishes a board when it is
  favorited onto a communicator. The filter is not redundant with it: legacy
  rows predate the hook, boards can be unpublished afterwards from the editor,
  and a board owned by someone other than the page owner is deliberately never
  auto-published. `public_page_board_ids` (the ETag/freshness helper) derives
  from `communication_boards`, so it follows the filter for free.
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
- **A parent can add their OWN chip to a preset row, stored in the same array
  behind `Profile::CARE_CUSTOM_OPTION_PREFIX` (`custom:`).** The preset lists are
  deliberately short, so an answer that isn't on the list is typed rather than
  missing. Three things make the sentinel work. The prefix contains a colon and a
  registry option key is `/\A[a-z_]+\z/`, so a custom value can never collide
  with a present or future key. It lives IN the array rather than beside it,
  because a deployed client — the iOS/Android bundles live a long time —
  round-trips `values[<field>]` verbatim and so preserves a chip it has never
  heard of, while a sibling key would be dropped by the frontend's
  `settingsFromCareValue` on that client's next save. And `CareLabels.option`
  guards the prefix in ONE place, returning the parent's words verbatim, so the
  printed plan and anything else server-side gets it right without knowing the
  feature exists — `humanize` would otherwise eat the underscores out of their
  own text. Custom chips are capped per field (`MAX_CARE_CUSTOM_OPTIONS`) INSIDE
  `MAX_CARE_MULTI_SELECT`, deduped case-insensitively, and cleaned through
  `CareText` like every other free-text value.
- **Detail lines on a BUILT-IN section are accepted but no longer offered.** The
  label/value rows under each built-in section were once its only free-text
  surface; custom chips and a per-section `short_text` field replaced them and
  the editor stopped rendering "+ Add a line". `clean_care_items` is still wired
  into `clean_builtin_care_section` on purpose, and removing it is the same
  silent-erasure trap as deleting an option from `CARE_SECTIONS`:
  `sanitize_care_settings` is a `before_save` over the whole blob, so the rows
  would vanish from every profile on its next save for any reason. `rake
  care:audit_items` is the gate — only once it reports zero is the call safe to
  delete. The editor still renders stored rows so a parent can clear their own,
  and the card and printed plan still show them. Custom sections keep offering
  rows; that is now the only place a label/value pair is authored.
- **Every built-in section carries exactly one `short_text` field.** Retiring the
  detail lines left Communication, Personal care and Moving around with no
  free-text surface at all, so each gained a `notes` field. The "exactly one"
  rule is asserted in `spec/models/care_preset_reshape_spec.rb` — two free-text
  boxes side by side just split the same answer.
- **The text cleaner strips markup and stores it UNESCAPED — `CareText.clean` is
  the single rule.** The trap is that `strip_tags` escapes entities on *output*,
  and the cleaner runs in a `before_save`, so a lone `strip_tags` PERSISTS
  "hugs &amp; quiet spaces" — the escaped string is what lands in the column and
  what both consumers then print verbatim (the public page renders each value as
  a React text node, the care plan ERB uses plain output tags; neither uses
  `raw`). So `CareText` strips, unescapes, and does it **twice**: the second
  strip removes markup the first unescape can reveal (`&lt;script&gt;` as typed
  input), and the second unescape undoes that strip's own re-escaping. Stopping
  after one unescape leaves the ampersand escaped, which is the whole bug —
  adding a "safety" `strip_tags` at the end reintroduces it. The rule is
  idempotent, so re-saving can't compound the escaping. `CareTextRepair` +
  `rake care:audit_escaped_text` / `care:unescape_text` fix rows written before
  this existed; the repair reuses `CareText` rather than a bare
  `CGI.unescapeHTML`, because unescaping a legacy escaped tag without stripping
  would write live markup back into the column.
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
- Care info is deliberately **not** on the device tag; that is an emergency
  artifact and a finder's route back to the owner. The **care plan** is what
  carries it — see below. This rule used to name the Safety ID card too; that
  card is no longer offered — see "The retired Safety ID card".

## The care plan PDFs

`Communicators::GenerateCarePlan` builds owner-downloadable documents from the
same data the two gated reveals serve, at one of three physical **sizes** —
`sheet` (the original flowing Letter document), `half` (one Letter page,
folded once), and `wallet` (one Letter page, 4-up fold strips). Two variants
times three sizes, minus one:

| variant | sheet | half | wallet |
|---|---|---|---|
| `:full` | `care_emergency_plan_pdf` | `care_emergency_plan_half_pdf` | `care_emergency_plan_wallet_pdf` |
| `:care_only` | `care_plan_pdf` | `care_plan_half_pdf` | *(not offered)* |

Each cell also has a `*_preview_png` twin holding the thumbnail — see "Each
document carries a PNG thumbnail" below.

`:care_only` + `wallet` is deliberately absent — strip the emergency block out
of a wallet card and what's left is a name, a photo, and a few care lines,
which isn't worth the paper. `GenerateCarePlan.supported?(variant, size)`
answers this without raising; the endpoint uses it to return 422
`unsupported_size` rather than emitting the card. An unrecognized size string
gets its own 422 `unknown_size`, checked before that.

`POST /api/profiles/:id/care_plan?variant=&size=` (size defaults to `sheet`)
— one route, both as params, behind the controller-wide owner gate. **Nothing
is added to the public MySpeak page**: the page keeps its two gated reveals
and gains no download button, so this introduces no new path to emergency
data.

- **`half` and `wallet` are fixed single pages, not flowing documents** — the
  opposite failure mode from `sheet`'s "however many pages it takes." They're
  `overflow: hidden` boxes sized in physical units (in, pt), so a maxed-out
  profile clips silently unless something intervenes.
  `CarePlanDocument#half_condensed?` / `#half_truncated?` are a weighted-count
  proxy for "would this overflow" — there is no headless Chrome available at
  spec time to actually paginate against, so the half size's overflow ladder
  (full chips → comma-joined text → `#condensed_care_lines` with a
  "Full plan on my live page" note) is driven by that heuristic rather than a
  real layout measurement. The wallet size skips the ladder entirely and
  always renders `#condensed_care_lines` capped at both a line COUNT
  (`GenerateCarePlan::WALLET_LINE_LIMIT`) and a per-line character length
  (`WALLET_LINE_MAX_CHARS`) — a maxed-out section's joined values run to
  hundreds of characters on their own, and capping only the line count let
  one long line silently overflow the 2in strip on its own.

  **The line count and the character cap are ONE budget, and the half size's
  last-resort tier needs both too** (`HALF_TRUNCATED_LINE_LIMIT` /
  `HALF_TRUNCATED_LINE_MAX_CHARS`). That tier had only a line cap, on the
  theory that a 4.5in back panel is roomy — but eight lines that each wrap to
  four visual lines is thirty-two lines, and the panel clipped the last of
  them plus its own footnote. Pick the pair together: characters that fit N
  visual lines, times a count that fits the panel at N.

  `#condensed_care_lines` cuts on a WORD boundary. The lines are a
  comma-joined list of short care options, so a mid-word cut lands inside one
  and prints a fragment ("Keep my device close, Wai…") that reads as a
  different answer from the one the parent picked.
- **A long unbroken token (a 300-character short_text field with no spaces,
  a URL) needs `overflow-wrap: break-word` on `body`** in
  `layouts/pdf_care_plan.html.erb` — without it such a token doesn't wrap, it
  overflows its box, and on the fixed-height half/wallet sizes
  `overflow: hidden` makes the excess vanish rather than merely spill visibly.
  A flex-row value column (`.condensed-lines .cline .v`, `.wlist .li .v`)
  additionally needs `flex: 1; min-width: 0` — a flex item's default
  `min-width: auto` refuses to shrink below its own content's natural width,
  which overflows the row even with `break-word` set.
- **A fixed-height fold face is a flex column, and a flex column SHRINKS
  before it overflows.** `.fpanel` (half) and `.wstrip .half` (wallet) are
  fixed-height `overflow: hidden` flex columns, so an over-full face doesn't
  spill — the flex algorithm takes the height out of whichever child can give,
  and that child then clips its own content in silence. It picked the glance
  strip, which printed as a row of half-height cells with "Allergies" and
  "How I talk" sliced through the middle: a layout bug that looks like a
  content bug. `.fpanel > *` and `.wstrip .half > *` are pinned to
  `flex: none` so nothing on either face may shrink. The honest failure for an
  over-full face is content running past the fold, which is visible; the
  overflow ladder is what stops it getting there.

  For the same reason, anything that CENTRES content inside such a face uses
  `justify-content: safe center`, never plain `center` — plain `center` splits
  an overflow across both edges, and on a back face that means spilling over
  the fold onto the front.
- **One subject per face on both fold sizes.** Front: who this is and who to
  call (identity, allergies, contacts). Back: day-to-day support. The wallet
  card used to keep the contacts on the back above the care lines with a
  one-line "Call first" repeat of the top contact squeezed onto the front,
  which printed the same phone number on both faces of a card small enough to
  read at a glance, and left the front half-empty while the back overflowed. A
  reader turning the card over should be answering a different question, not
  re-reading the last one.
- **`half` and `wallet` print single-sided; the back face is authored upright
  and rotated 180deg by a `.flip` class** (folding print-side-out applies
  exactly that rotation — see the CSS comment above `.flip` in the layout for
  the full derivation). This bit once, badly: the multi-line CSS comment
  documenting the rotation was closed with an ERB `%>` instead of a CSS `*/`,
  which left the comment OPEN and silently swallowed every rule up to the next
  real `*/` — `.flip`, `.foldrule`, and `.foldrule span` all included. Nothing
  in the rendered HTML or a stubbed-Grover spec catches this (the class names
  are all still present, and a spec never renders through real Chrome); it
  only showed up as flat, unrotated back-face content in an actual printed
  PDF. If a folded `half` or `wallet` print ever comes out both faces
  right-side-up (i.e. the back face rotation silently stopped applying), check
  for exactly this before touching the rotation math itself.
- **Section cards carry their own colour and icon**, keyed by
  `CarePlanDocument.style_key_for` (`STYLE_KEYS`: comm/care/meal/sens/move/
  trav) and rendered via `CarePlanIcons.svg_for` (inline SVG — the layout's
  no-network rule applies to icons same as fonts). A custom section maps to
  `"trav"` (navy) rather than getting a colour of its own, so four
  parent-authored sections don't turn the sheet into a paint chart.
- **The glance strip's "How I talk" (`#glance_how_i_talk`) is derived from the
  communication section independently of `only_sections`.** It introduces the
  person; narrowing the printed sections to "meals only" shouldn't erase how
  the subject talks. A communication section the parent explicitly disabled
  (`enabled: false`) is still respected, though — that's a real "nothing to
  say" state, not a filter.
- **The line under the name is the CALLER's `subheader`, not derived data, and
  its default is never stored.** `subheader` supplies the words,
  `include_subheader: false` drops the line, and blank or absent means the
  default copy (`care.document.subheader.default`), resolved at RENDER time.
  Storing that default would break the same rule `profiles.bio` /
  `profiles.intro` are under — the line prints in the communicator's own
  first-person voice, so seeding it publishes words nobody wrote and makes "is
  there a subheader" stop meaning "did someone write one". Blank and absent are
  the SAME answer here, unlike `sections`, where `[]` is a real request.
  `SUBHEADER_MAX_CHARS` caps it because it rides the freshness signature.

  It used to be `CarePlanDocument#says`, a sentence built from the
  communication answers ("I communicate using AAC device and gestures. Keep my
  device close.") — which restated the "How I talk" glance cell a centimetre
  below it. The struct, the `care.document.says.*` keys and the derivation are
  all retired; `#glance_how_i_talk` still carries that fact.

  The controller's `include_subheader` is **absent-means-included**: reading a
  missing param through `truthy?` would have silently dropped the line from
  every download made by the client in production, which predates the option
  and sends neither param. Rendered by `sheet` and `half`; the wallet's 2in
  front face has no room and doesn't ask for it.
- **The "At a glance" strip is two cells, not three.** It carried a third
  "Call first" cell repeating the first contact's phone number — a few
  millimetres above the contact cards in the emergency block directly below
  it, on both sizes that render the strip. The contact list is ordered and its
  first entry IS the one to call, so the cell said nothing the page didn't
  already say, and on the half size it was part of what pushed the front face
  over its height budget. `CarePlanDocument#call_first_contact` went with it.
- **Allergies render in the "At a glance" strip and nowhere else.** The
  emergency grid's field loop explicitly skips `field.key == "allergies"`;
  `CarePlanDocument::EMERGENCY_FIELDS` still includes it (nothing else changes
  there), it just never reaches that particular loop. Printing it twice was
  the first design pass's bug.

`&sections=` narrows the document to an allowlist of care section keys (the
download picker in the frontend's `CarePlanOptionsModal`). Accepted as a
comma-separated string or an array.

Things that will bite a future change:

- **`sections` absent is not `sections` empty.** Absent means every stored
  section — what every caller sent before the picker shipped, and what keeps
  those documents' signatures stable. Empty means none of them, which on the
  `:full` variant is a real request for the emergency page alone. `Array(nil)`
  collapses the two, so every hop (controller → `GenerateCarePlan` →
  `CarePlanDocument`) guards on nil explicitly.
- **A selection that doesn't reach `GenerateCarePlan#signature` does nothing at
  all.** There is one attachment per variant, so a narrowed request would be
  answered by the cached full document and the picker would appear to be
  ignored. The corollary is that a narrowed download REPLACES the stored
  document, so `care_plan_url` on `Profile#api_view` can point at a narrowed
  sheet until the next download — acceptable because the client regenerates on
  every click.
- **The selection also has to reach `.printable?`.** Otherwise a `:care_only`
  request narrowed down to nothing prints headings over nothing, which is the
  exact "a finished plan that says this child needs nothing" failure the 422
  exists to refuse.
- Section keys need no validation: they are only ever intersected with the
  profile's own stored keys, so an unknown one can only remove sections. The
  list is capped in the controller because it rides in the signature.

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
- **Each section is a `.card` with `break-inside: avoid` on the sheet size,
  not a `.section-keep` heading-plus-first-row wrapper** (that mechanism was
  deleted; don't restore it). This is safe only because a section is
  half-width in a two-column layout and prints one line per field — the
  tallest realistic card (Meals, four fields, one a 300-character
  `short_text`) is around 1.1in in a column, so the rare one that outgrows a
  column gets split by Chrome rather than clipped, which is the accepted
  failure. If cards ever grow tall enough to routinely exceed a page, revisit
  this rather than adding `column-fill: auto`.
- **An empty plan is refused, not printed.** `GenerateCarePlan.printable?` is
  checked in the controller (a service that raises can't answer 422):
  `care_only` with no care info → `no_care_info`; `full` with neither →
  `nothing_to_print`. `full` on emergency info alone still prints — that's the
  hospital-bag case. Blank emergency fields are OMITTED under
  `CarePlanDocument::OMIT_BLANK_EMERGENCY_FIELDS` (the opposite of printing
  "None listed" per field) and named collectively in one muted line instead —
  `#blank_emergency_field_names` — so "nobody answered this" stays
  distinguishable from "there is nothing here" at a tenth of the height ten
  per-field rows used to cost.
- **`Communicators::CarePlanDocument` is a port of `resolveCareSections`**
  (frontend `src/data/careSections.ts`). The labels are not duplicated —
  `CareLabels` serves those — but the walk over stored settings genuinely
  exists twice, because one renders server-side and one client-side. Change
  both.

### Each document carries a PNG thumbnail

Every `[variant, size]` pair has a `preview:` attachment beside its
`attachment:`, in the same `VARIANTS` table — a size added without one attaches
nothing and shows a placeholder forever, which is why they travel together.
`ChildAccount#api_view` serves them as `*_preview_url` (never
`#index_api_view`: ten attachment lookups per communicator multiply across a
dashboard).

- **One render, two Grover calls.** `#call` evaluates the ERB once and hands
  the same HTML string to the PDF and to `HtmlToPng`. The render is the
  expensive, side-effect-carrying half — it resolves the avatar to a data: URI
  and walks the whole care blob — and rendering per output would also let a
  document and its own thumbnail drift apart.
- **The freshness check covers BOTH, and that is what backfills previews.**
  `#up_to_date?` requires the PDF *and* the preview to be attached and fresh;
  checking only the PDF would leave every document cached before previews
  existed "fresh" forever, with a working download beside a placeholder and no
  way for the owner to force one. This is also why previews shipped with **no
  `LAYOUT_VERSION` bump** — the PDF bytes did not change, and a bump would
  rebuild every cached document to no purpose.
- **Margin parity is a `@media screen` block** in
  `layouts/pdf_care_plan.html.erb`. Chrome emulates PRINT media for `to_pdf`
  and SCREEN media for `to_png`, so that block reaches the thumbnail and
  nothing else — it reproduces the page margins Grover's `margin:` option gives
  the `sheet` size on paper, which a screenshot otherwise gets none of. Setting
  `emulate_media: "screen"` on the PDF path would double-margin the sheet.
  `half` and `wallet` render at `margin: 0` in physical units against the full
  page, so at a Letter-sized viewport they already match and are deliberately
  left alone.
- The viewport is Letter at 96dpi (`PREVIEW_WIDTH`/`PREVIEW_HEIGHT`, 816×1056)
  at 2x. `HtmlToPng` captures the viewport rather than the full page, so on the
  flowing `sheet` size the thumbnail is page one.


## The retired Safety ID card

`Communicators::GenerateSafetyIdCard` printed exactly
`CarePlanDocument::EMERGENCY_FIELDS` plus `profile.safety_contacts` — the same
data as the care plan's emergency page, on a 1200×1800 portrait poster. Once
the `wallet` size shipped, that card was a strict content subset of a document
someone can actually carry, so it came off the Print & share tab.

**Nothing was deleted.** `safety_id_png` / `safety_id_pdf`,
`POST /api/profiles/:id/safety_id`, and `communicators/assets/safety_id_card`
all remain, so no already-generated card is orphaned and re-offering it is a
UI change. What changed is that nothing builds one *unprompted*:

- `Profile#generate_attachments!` no longer calls it. That method runs
  synchronously on every safety-profile save, so this halved it from four
  headless-Chrome renders to two — paid for by an avatar upload or a theme
  tweak.
- `RegenerateSafetyCardsJob` no longer re-renders it after a slug change.
- `API::Internal::ProfilesController`'s **`qr_target_url` branch still does**,
  explicitly. That is the AAC Classroom Kit pointing sample tags at
  `/classroom`, and it is the reason the generator and endpoint stay.

`Marketing::SafetyTagSheet` is unrelated and unaffected — it is the fillable
clip-on kit tag, with no per-child data.


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
  gated `safety_view` POST. Also printed on the care plan's `full` variant.

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
  URL.
- **Every creation path leaves the slug blank — that is the rule, not a detail
  of the wizard.** `ChildAccount#create_profile!` (the auto-minted page behind
  `API::ChildAccountsController#create`, i.e. the dashboard) used to force a
  name-derived slug, so the path most users take produced a *guessable*
  `/my/river-stone` while the wizard's was unguessable. Nothing re-slugs a page
  afterwards, so the emergency info a parent filled in later sat behind a URL
  anyone could derive from the child's name. It now passes no `slug:` at all and
  lets `ensure_slug` do its job; `sluggify_for_profile` and its collision-suffix
  dance went with it. A new creation path passes `username:` and never `slug:`
  (#774).
- **Not user-editable:** `Profile#slug_editable?` returns `false` when
  `slug_type == "random"`, regardless of the 7-day edit window — letting the
  owner rename the page back to the child's name would undo the protection.
  `slug_type` and `slug_editable` are exposed on `Profile#api_view` (which is
  what a communicator page's edit form reads, nested under
  `ChildAccount#api_view`).
- **Locked FOREVER and locked UNTIL are different answers, and the client has
  to tell them apart.** `Profile#slug_permanent?` (`slug_type == "random"`) is
  the first check in `slug_editable?` and the reason `API::ProfilesController#update`
  answers **422 `slug_permanent`** rather than `slug_locked`: the 7-day copy is
  built around a `next_edit_at`, and a random slug has none — `slug_changed_at`
  is blank because nothing has ever edited it, so `slug_editable_at` is nil and
  the message rendered as "You can change your link again on ." A client that
  derives its lock state from the *timestamp* alone therefore reads a random
  slug as unlocked and offers an edit that can only fail; read `slug_editable`.
  Admins still bypass both at the controller layer.
- **Legacy fallback:** the migration preserves the old slug in
  `profiles.legacy_slug` (conditional unique index, NULLs allowed).
  `API::ProfilesController#public` falls back to `legacy_slug` and
  **301-redirects** to the current slug, so printed cards / bookmarks keep
  working. `Profile.slug_available?` also checks `legacy_slug` so a freed-up old
  slug can't be re-squatted.

## Three addresses: `slug`, `permanent_slug`, `legacy_slug`

A profile resolves through three columns, and they answer different questions.
`Profile.resolve_slug` is the ONLY thing that knows all three; it returns
`[profile, :canonical | :permanent | :legacy]`.

| column | what it is | on a match |
|---|---|---|
| `slug` | the address a person reads; may change | serve |
| `permanent_slug` | what a printed QR resolves through; assigned at create, never rewritten | serve **directly** |
| `legacy_slug` | a deprecated address | **301** to `slug` |

- **Why the split exists.** Paper needs an address that never moves; people need
  one they can change or revoke. One column can serve only one of those, and
  the moment a rename had to preserve the printed target, `slug` had to be
  frozen — which is precisely what left a leaked link unrevocable. Separating
  them is what makes both possible.
- **A `permanent_slug` match is served, not redirected.** Redirecting it would
  make the printed address depend on whatever `slug` holds today, which is the
  one thing it must not do. `legacy_slug` still 301s, because that one really is
  deprecated.
- **`Profile#permanent_url` is what every printed artifact renders** —
  `GenerateDeviceTag`, `GenerateSafetyIdCard`, and `GenerateCarePlan` (which
  also prints the URL as readable text beside its QR, since these get
  photocopied). None of them may use `public_url`.
- **Every public surface must resolve all three**, or a link half-works: the
  page opens and the gated Emergency Info reveal 404s behind it. `#public`,
  `#safety_view`, `#care_view` and `#check_placeholder` all go through the
  resolver for that reason.
- **Nullable, with a fallback.** `printable_slug` is `permanent_slug || slug`,
  so a row the backfill hasn't reached keeps working and simply doesn't have the
  guarantee yet — which is exactly what its already-printed tag says anyway.
  Backfill: `rake profiles:backfill_permanent_slugs`, dry-run by default. It
  deliberately does **not** re-render tags; an existing tag points at the
  current public slug, which still resolves, and mass-regenerating would email
  every parent about a card that works fine.
- `Profile.generate_random_slug` and `.slug_available?` check all three columns
  — a "fresh" random slug that collided with a printed QR target, or a public
  slug someone set to another profile's `permanent_slug`, would hijack a tag.

## Revoking a link (`rotate_slug!`)

An unguessable URL is still a **bearer token**: whoever a `/my/s-k8x2mf` link
was shared with — a school aide, an ex-partner, a group chat — keeps access
until the address changes. `POST /api/profiles/:id/rotate_slug` ("Get a new
link") is the answer, and it is deliberately not renaming.

- **It does not keep the old address.** `legacy_slug` exists to stop a rename
  breaking shared links; here breaking them IS the request, so the old slug is
  dropped and any stored `legacy_slug` is cleared as well. A leaked address that
  still 301s is not revoked.
- **Not gated on `slug_editable?`.** That governs choosing a *name*; refusing to
  revoke until a 7-day window opens would be backwards.
- **It costs no reprint** — the QR resolves through `permanent_slug`, which
  rotation never touches. `RegenerateSafetyCardsJob` still runs once, for a tag
  rendered before the column existed; after that first rotation a profile's
  paper is immune to every future one. A row with no `permanent_slug` gets one
  before rotating, so rotation self-heals rather than stranding that tag.
- Owner-only (`can_manage_profile?`, the same rule `#update` enforces), admins
  included. The response echoes `previous_slug` so the UI can say what stopped
  working.
- **Backfill + cards:** `rake profiles:migrate_to_random_slugs` is **dry-run by
  default** (reports what would change, enqueues nothing); apply with
  `DRY_RUN=false`, scope with `USER_ID=N`. When applied it migrates every
  matching profile (via `update_columns`, skipping validations/callbacks) and
  enqueues `RegenerateSafetyCardsJob` for **only the profiles migrated in that
  run** (so a re-run / scoped run doesn't re-email parents whose cards are
  current). Its scope mirrors `Profile#safety_profile?` — ChildAccount-owned
  **or** `profile_kind: "safety"` — because `set_kind` only rewrites User-owned
  rows, so a placeholder claimed by a communicator stays
  `profile_kind: "placeholder"` and a kind-only scope walked straight past a
  page that is very much a child's. The guard is `slug_type` **not** `"random"`
  rather than `== "legacy"`: anything not already random still has a
  name-derived URL to retire, and it is what makes re-runs no-ops.
  **Note what the backfill does and does not buy you:** it preserves the old
  slug as `legacy_slug`, and the public endpoint 301-redirects it, so the
  guessable name-derived URL keeps resolving for a migrated page. That is
  deliberate (a parent may have texted the link), but it means the backfill
  moves the canonical URL without making an already-exposed page unfindable —
  only new pages are unguessable from birth.
  That job re-renders the device tag with the new QR target
  (`Communicators::GenerateDeviceTag` with `regenerate: true`) and emails the
  parent via `CommunicationAccountMailer#safety_cards_updated`. Run after
  deploy so the legacy fallback is live before slugs change. It no longer
  re-renders the Safety ID card — see "The retired Safety ID card".


## Limits — what a MySpeak page costs, and what it doesn't

Two different products live in the `profiles` table, and they have two different
quotas. Conflating them is what broke #761.

| Product | `profile_kind` | `profileable` | URL | Quota |
|---|---|---|---|---|
| **MySpeak page** | `safety` | `ChildAccount` | `/my/:slug` | The **communicator slot** (`Permissions::CommunicatorLimits`). Nothing else. |
| **Public page** | `public_page` | `User` | `/u/:slug` | One per user, structurally (`User has_one :profile`). Plan-independent. |

- **A communicator's MySpeak page is free on every plan** — which is what the
  frontend copy has always promised (`en.json` "free on every plan, including
  Free", plus the dashboard's "Free on every plan" badge). Every communicator
  auto-mints exactly one Profile at create time
  (`ChildAccount#create_profile!`, called from `API::ChildAccountsController#create`),
  so a page is never something the user asks for separately. There is no
  per-Profile counter and no `FREE_MYSPEAK_ID_LIMIT`; both were removed in #761.
  **Never reintroduce a Profile count as a quota.** It charges
  `Permissions::CommunicatorLimits` a second time for the same communicator, and
  it does so from `POST /api/child_accounts` — a path that doesn't know the limit
  exists — so the slot is consumed silently and the user is refused a page they
  were told is free. That is exactly how a Free SLP with one communicator ended
  up unable to create anything, having "never created one."
- **The user-level Public page is one per user.** `API::ProfilesController#create`
  answers a duplicate with **409 `public_page_exists`** (carrying `profile_id`
  and `slug` so the client can switch to an update), not a 403 — it is a state
  conflict, not a plan gate. A second row would be unreachable anyway, since
  `user.profile` returns an arbitrary one of them. Note there is **no DB unique
  index** on `(profileable_type, profileable_id)`; the controller guard is the
  only thing holding the invariant on the write path.
- **`POST /api/profiles` is USER-OWNED ONLY and can never create a
  communicator's MySpeak page.** It hardcodes `profile.profileable = current_user`
  and `profile_params` permits no `profileable`, so the endpoint has exactly one
  possible owner. The trap is on the client: `ProfileForm` — which is the
  *communicator* MySpeak editor, rendered six times on `ViewChildAccountScreen`
  with `existingProfile={communicatorAccount.profile}` — falls back to this
  endpoint when that profile is missing (`existingProfile?.id ? update : create`).
  A communicator's `profile` is optional (`ChildAccount#create_profile!` returns
  early when the username won't sluggify), so that fallback is reachable, and it
  mints a stray **User-owned** page that never attaches to the communicator.
  The 409 above makes it fail loudly for a user who already has a page rather
  than silently succeeding at the wrong thing; the real fix is client-side
  (`itty-bitty-frontend#745`). A communicator's page is minted exactly once, by
  `ChildAccount#create_profile!` at communicator-create time — never by a form
  save.
- **`resources :profiles` is `only:`-scoped** (and the `namespace :account` one
  is `only: []`). The controllers define no `destroy`/`new`/`edit`, and a bare
  `resources` routed `DELETE /api/profiles/:id` straight at a missing action —
  `AbstractController::ActionNotFound`, a 500. It now falls through to the
  catch-all 404. There is still **no delete path for a Profile** from anywhere
  in the app; a page is removed only as a side effect of `User#destroy`
  (`dependent: :destroy`), and notably *not* by `ChildAccount#destroy`, which
  carries no `dependent:`.
