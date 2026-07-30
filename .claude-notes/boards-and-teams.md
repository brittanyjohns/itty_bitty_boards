# Boards & teams — permissions, assignment, deletion, sets, layouts, imports

> Extracted from CLAUDE.md on 2026-07-11 (hub-and-spoke restructure).
> This file is the authoritative doc for this subsystem — update it (not CLAUDE.md)
> when behavior changes. CLAUDE.md keeps only the cross-cutting invariants.

## Team permissions — owner protection

Communicators (`child_account`) have an `owner_id` (the family/parent
post-claim, or the SLP pre-claim). That user is "**owner-pinned**" on the
communicator's team: they cannot be removed or have their role changed by
any non-owner. Full matrix in issue #166. Server-side rules:

- `ChildAccount#claim_by!` (the SLP→family hand-off) updates the
  communicator's **own** team: new owner → `admin`, previous owner →
  `supervisor`, and **team ownership (`created_by_id`) transfers to the new
  owner** so they get `is_owner` / `can_invite` (the "Manage team" controls).
- **"Own team" is resolved deterministically, not `teams.first`.** A
  communicator can belong to several teams (its own + shared/board teams it's
  added to), so `ChildAccount#primary_team` resolves: (1) the team pinned in
  `settings["primary_team_id"]`, (2) the namesake team
  (`"<name>'s Communication Team"`, the creation convention), (3) the oldest
  team as a legacy fallback. `ensure_team!` and `claim_by!` pin
  `primary_team_id` so resolution stays stable across renames and join order.
  Before this, `claim_by!` acted on `teams.first` and could update the wrong
  team — leaving the communicator's own team without the new owner.
  Existing stale data is repaired by `rake communicators:repair_handoff_teams`
  (dry-run by default; `DRY_RUN=false` to apply, `USER_ID=N` to scope). It only
  touches a communicator's identifiable own team — never a shared one.
- **Lending / hand-off is Pro-only, enforced server-side.**
  `API::ChildAccountsController#require_pro_for_lending!` gates `lend` and
  `promote_to_loaner` (after the ownership check, so a non-owner still gets the
  generic Unauthorized) and returns **HTTP 403 `pro_required`** for non-Pro
  non-admin callers. Covers the `active→loaner` lend path too, which skips the
  slot check. The frontend `LoanerControls` Pro gate is now defense-in-depth,
  not the only guard.
- **Roster + delete are owner-scoped.** `ChildAccountsController#index` scopes
  on `owner_id` (the canonical ownership column that slot counts and serializers
  use), not the legacy `user_id` mirror — so the listed communicators can't
  diverge from the "X of Y" slot numbers, and a loaner stays listed under its
  lender until claimed. `#destroy` authorizes on `owner_id` and, like `#archive`,
  **refuses a `loaner`** (HTTP 422, "End the loan first via end_loan.") so a live
  claim link is never orphaned mid-hand-off.
- `DELETE /api/teams/:id/remove_member` returns **HTTP 403
  `cannot_remove_owner`** if the target is owner-pinned and the caller is
  neither that user nor a system admin. The owner can remove themselves.
- `DELETE /api/teams/:id/leave` — self-scoped: a member removes their own
  membership (uses `current_user`, never an email param, so it can't remove
  anyone else). Returns **HTTP 403 `creator_cannot_leave`** for the team
  creator (`created_by_id`) — they use "Delete team" instead, since leaving
  would orphan the team. Destroying the `TeamUser` fires the same
  `before_destroy` board-snapshot safety net as `remove_member`, so the
  departing member's shared boards stay with the family.
- `POST /api/teams/:id/invite`, when it would change an *existing*
  membership's role, returns **HTTP 403 `cannot_change_owner_role`** if
  the target is owner-pinned (and the caller isn't that user). It also
  returns **HTTP 403 `cannot_self_promote`** if a non-owner non-admin
  caller tries to set their own role to `admin`.
- Owner-pinned-ness is computed, not stored:
  `Team#account_owner_ids` / `Team#account_owner?(user)` and
  `TeamUser#account_owner?`. Team `show`/`index` `api_view` expose
  `account_owner_ids` and per-member `is_account_owner` so the frontend
  can hide destructive controls.

The SLP→family **hand-off** (loaner → claim) is the supported ownership
transfer: `claim_by!` moves both `child_account.owner_id` and the own team's
`created_by_id` to the new owner. A standalone **transfer ownership** endpoint
(active → another user directly, outside the loaner flow) still doesn't exist —
out of scope for #166.

**Full SLP→parent handoff contract** — including the permissions matrix
(who can do what to a claimed communicator), the lifecycle states, and
known backend-enforcement gaps — lives in
`marketing/.claude-notes/handoff-workflow.md`. Keep that doc and this
section in sync when the rules change.

### Board assignment is a DEEP clone (`Boards::AssignmentCloner`)

Putting a board on a communicator (`assign_boards`, `assign_accounts`, the
MySpeak starter attach) goes through **`Boards::AssignmentCloner`**
(`app/services/boards/`), not a bare `clone_with_images`. The old shallow
clone copied `predictive_board_id` verbatim, so an assigned board's folder
tiles kept opening the **source owner's live sub-boards** — shared state that
changed/broke when the source owner edited or deleted them.

- The cloner BFS-collects the linked set (**`Boards::PredictiveLinkSet`**,
  extracted from `SeededSetCloner` and shared with it), depth-capped by
  `BOARD_ASSIGN_CLONE_DEPTH` (default 3), clones each sub-board for the same
  owner, and rewires the folder tiles to the clones. Pointers past the depth
  cap are **kept verbatim** (assignment sets are arbitrary user boards —
  nulling would break deep sets), unlike the builder's `:null` policy.
- Root clone contract unchanged: `is_template: true` + ChildBoard on the
  communicator (created inside `clone_with_images`). Sub-clones are also
  `is_template` (via the new `force_template:` kwarg on `clone_with_images`),
  get **no ChildBoard rows**, and carry `settings["assignment_child"]` +
  `["assignment_root_id"]` so `ChildBoardsController#destroy`'s **orphan
  sweep** can delete them when the root clone is removed and hard-deleted
  (same `orphan_template?` guards per sub-board; iterates until a pass
  deletes nothing so nested folders unwind).
- **Per-communicator assigned-board cap** (`ChildAccount.max_assigned_boards`,
  ENV `MAX_ASSIGNED_BOARDS_PER_COMMUNICATOR`, default 80 — matches the
  favorites cap): assigned clones are deliberately uncounted toward the
  owner's board limit (the original already counted), so this cap is what
  stops assignment minting unlimited board rows. `assign_boards` returns
  **422 `assigned_board_limit`** `{ error, message, limit, count }`;
  `assign_accounts` appends a per-communicator message to its existing
  `record_errors` 422 array.
- Legacy shallow clones (no `assignment_root_id` marker) behave as before —
  nothing migrates them; the delete-safety 409 now correctly warns source
  owners that their sub-boards are still referenced.

### Board removal after hand-off (non-destructive)

Boards put on a communicator via `assign_boards` are **cloned** (a new
`Board` marked `is_template: true`, owned by the user who added them — the
SLP), referenced by a `ChildBoard` join. After a hand-off the new owner
should be able to clear/curate the dashboard **without losing boards**.

- **On claim, `claim_by!` registers the communicator's current dashboard
  boards as team boards** (`register_dashboard_boards_on_team!`) on its own
  team. While a board is on the dashboard it's excluded from
  `available_teams_boards` (no duplicate); once removed it reappears there,
  re-addable. The `repair_handoff_teams` rake task backfills this for
  already-claimed communicators.
- **Removal is non-destructive.** `DELETE /api/child_boards/:id`
  (`ChildBoardsController#destroy`) always detaches the `ChildBoard`, and
  only hard-deletes the underlying `Board` when it's an **orphan template**
  (`is_template` AND no `team_boards` AND not on another communicator AND
  owned by the remover — `orphan_template?`). So a hand-off owner removing
  an inherited board (a team board / SLP-owned clone) detaches it but keeps
  it; the old "delete the board whenever `is_template`" behavior only still
  applies to a true throwaway clone on your own communicator.
- **Detach stays owner-gated; the api_view exposes `can_remove`.** Detach
  authorization is communicator-ownership (`editable_by?`), not board
  ownership, so the new owner is allowed. The dashboard board entries now
  carry **`can_remove`** (keyed to communicator ownership) alongside
  `can_edit` (board ownership, gates clone-to-edit), so the frontend can
  show the remove control to a hand-off owner who doesn't own the board.
  (Frontend wiring to consume `can_remove` is a companion change.)
- **`Board#communicator_child_boards` filters orphaned join rows.** It unions
  `original_child_boards` (FK `original_board_id`, `dependent: :nullify`) with
  `child_boards`, then `.select(&:child_account)` — a `ChildBoard` whose
  `child_account` was deleted (account teardown, or older DBs lacking an
  enforced `child_account_id` FK) is dropped. The `api_view` /
  `api_view_with_predictive_images` serializers read `cb.child_account.id`
  directly, so a single orphan otherwise 500s the whole `/api/boards` index.
  Filter at this one chokepoint, not per call site.
### Editing the communicator object itself

`ChildAccount#editable_by?(user)` returns true iff the user is the
`owner_id` or a system admin. It's the helper that drives the
`can_edit_communicator` flag on both `api_view` and `vendor_api_view`
(issue #215). The frontend uses that flag to gate the Edit tab/form on a
communicator — i.e. who can change name, username, voice, layout, and
the safety profile.

`can_edit_communicator` is **distinct from `can_edit`** in the same
payload: `can_edit` answers "can this user curate boards on this
communicator" (board sharers, including team members on a paid plan).
`can_edit_communicator` answers "can this user mutate the communicator
object itself" (owner-only by default). Keep both — they back different
UI affordances.

Full permissions matrix and the rationale for the split lives in
`../speakanyway/marketing/.claude-notes/handoff-workflow.md`.


## Make a Board From Screenshot

Turns an uploaded screenshot of an existing AAC/communication board into a real
SpeakAnyWay `Board` using OpenAI vision. Three-step flow, async in the middle:

- **Upload** — `POST /api/board_screenshot_imports` (`name`, optional `columns`,
  and either `cropped_image` base64 data URL or multipart `image`). Creates a
  `BoardScreenshotImport` (`status: queued`), **spends 3 credits**
  (`screenshot_import` feature key) via `check_credits!`, stashes the spend
  transaction id on `import.metadata["credit_txn_id"]`, then enqueues
  `BoardScreenshotImportJob`. `columns` is sanitized to a positive Integer or
  `nil` (auto-detect) so a bad value can't fail the job after charging.
- **Analyze (async)** — `BoardScreenshotImportJob` (queue `:ai_images`,
  `retry: 1`): `ImagePreprocessor` resizes/deskews/contrast-boosts to a `tmp/`
  file → `BoardScreenshotVisionService#parse_board` (OpenAI **Responses API**,
  JSON mode, model `BOARD_SCREENSHOT_VISION_MODEL`, default `gpt-4.1-mini`)
  returns a full `rows × cols` grid → one `BoardScreenshotCell` per cell →
  `status: needs_review`. The preprocessed temp file is always unlinked in an
  `ensure`. On any failure the import goes `status: failed` **and the 3 credits
  are refunded** to their original plan/topup split (idempotent across the retry
  via a `refund_for_txn` marker).
- **Review + commit** — `PATCH /api/board_screenshot_imports/:id` lets the user
  fix detected `label_norm`/`bg_color`/`row`/`col` per cell (and `cols`); then
  `POST /api/board_screenshot_imports/:id/commit` runs `BoardFromScreenshot`,
  which builds a static `Board` (col→`x`, row→`y` explicit grid layout),
  resolves an `Image` per label, and links it back to the import. `commit`
  returns **422 `import_not_ready`** unless the import is
  `needs_review`/`committed`/`completed`.

**Staging:** `BoardScreenshotVisionService#parse_board` returns a deterministic
placeholder grid when `AppEnv.staging?` — no paid OpenAI call, no real credits
burned — mirroring the image-generation placeholder short-circuit. (The vision
call is **not** gated in real production.)


## OBF/OBZ import — copyright policy

Imports via `POST /api/boards/import_obf` are gated to avoid silently
pulling licensed symbol artwork (SymbolStix, etc.) into the public
image pool:

- **Default (no opt-in):** board structure imports, `Image` rows are
  created **`is_private: true`**, but **no image binaries are downloaded
  or attached to `Docs`**. The `attach_image_doc` step is skipped.
- **With opt-in:** client must send `include_images=true` AND
  `image_license_acknowledged=true`. Without the ack, the controller
  returns **HTTP 400 `image_license_required`**. The importer then
  calls `Down.download` per OBF image entry and attaches Docs.
- **`is_private: true` is non-negotiable.** Set in
  `Board.find_or_create_image_for_button` on every newly-created Image,
  regardless of opt-in. Existing images matched by label are returned
  as-is — we don't downgrade visibility on something the user already
  owns. Admin can flip individual images public later via existing UI.
- **Audit trail** lives on `BoardGroup.settings["imported_from_obf"]`:
  `include_images`, `license_acknowledged`, `acknowledged_by_user_id`,
  `acknowledged_at`, `imported_by_user_id`, and the OBF root board's
  `license` block (author, source URL, license type) if present.
- Plumbed through `ObzImporter#initialize(import_options:)`,
  `Board.from_obf(... import_options:)`, and `ImportFromObfJob#perform`
  (4th positional arg). All default to `{}` for backward compat with
  callers that don't care.
- **`Board.from_obf` returns a tuple** `[board, dynamic_data]`, not a bare
  `Board`. Callers must destructure: `board, _dynamic = Board.from_obf(...)`.
  Signature: `from_obf(data, current_user, board_group = nil, board_id = nil,
  import_options: {})` — don't swap `current_user` and `board_group`.

## OBF/OBZ export

`GET /api/boards/:id/download_obf` exports one board inline (synchronous).
`POST /api/boards/:id/export_package` (a board plus its predictive-link
reachable set) and `POST /api/board_groups/:id/export_package` (an explicit
Board Set) create a `BoardExport` and run `ExportBoardPackageJob` async;
`GET /api/board_exports/:id` (`show`) and `GET /api/board_exports/:id/download`
(`download`) serve the result.

- **Bundling and the declared license are independent decisions**, and both
  live in `Boards::ObfExporter`. `Images::RedistributionLicense.for` decides,
  per image doc, whether its bytes may be bundled into the zip.
  `ObfExporter#derived_license` decides, per board, what `"license"` the OBF
  document declares. A board of the user's own photos bundles every asset
  AND declares `"private"` — SpeakAnyWay has no standing to license a user's
  family photos under an open license on their behalf.
- **`Images::RedistributionLicense` is deliberately NOT `Images::CommercialLicense`.**
  `CommercialLicense` answers "may SpeakAnyWay SELL a product containing
  this" and fails closed hard: NC/ND licenses are excluded (they permit
  redistribution but not the specific rights a sale needs) and a blank
  `source_type` is untrusted. `RedistributionLicense` answers a narrower
  question — "may this be copied into a *user's own* export" — so it relaxes
  both: NC/ND don't forbid redistribution, so they're bundlable here; and a
  blank `source_type` is how uploads *predating* `Doc::SOURCE_TYPE_USER` are
  stored, so treating it as untrusted would strip a user's own photos out of
  their own export. `RedistributionLicense.for` resolves in this order —
  ownership before license, because a user's own content is theirs and its
  license is not ours to evaluate:
  1. `LicenseResolution.resolve(doc) == :protected` → not bundlable
     (proprietary symbol set), regardless of everything else.
  2. Owned by the exporting user (`source_type` in `[nil, "", "User"]` and
     the doc's or its parent `Image`'s `user_id` matches) → bundlable,
     `owned_by_user: true`, no license check at all.
  3. `source_type == "OpenAI"`, or owned by `User::DEFAULT_ADMIN_ID`
     (SpeakAnyWay-authored) → bundlable.
  4. `source_type == "GoogleSearch"` (scraped, no license of record) → not
     bundlable.
  5. Otherwise, normalize the resolved license type and check it against
     `REDISTRIBUTABLE_FAMILIES` (`public domain`, `cc0`, `cc by` — matched
     after stripping `-sa`/`-nc`/`-nd` suffixes, so `cc by-nc-sa` still
     matches `cc by`) → bundlable if it matches.
  6. Anything else (no license on record, unrecognized type) → not
     bundlable. The predicate fails closed.
  A stamped `user_id` alone is not authorship: `Board.from_obf` writes
  `ObfImport` docs with the importing user's id, so step 2 additionally
  requires a user-authored `source_type` — without that an import of
  someone else's proprietary symbols would re-export as the importer's own.
- **`ObfExporter#derived_license`** (there is no `Board#license` method —
  license is derived per export, not stored):
  - Any bundled asset with `owned_by_user? == true` → `"private"`. The
    user's own content overrides everything else in the board.
  - No asset was ever positively evaluated as bundlable — either every
    asset was skipped, or licensing never ran at all because the export
    used `asset_mode: :url` — → `"private"`. Absence of evidence of an open
    license is not evidence of openness; this only fires open when at least
    one non-user-owned asset was actually confirmed bundlable.
  - At least one non-user-owned bundlable asset, and none carried a
    recognized license type → the default open license
    (`CC BY-SA 4.0`).
  - Otherwise, the board declares the **most restrictive** license type
    among the bundled assets' types, chosen by `restrictiveness_score`
    (NC/ND/SA add weight), not by sorting the type strings — a board
    containing one `cc by-nc-sa` image and one `public domain` image must
    declare the former, not whichever type happens to sort last.
- **`ObfExporter::Result` carries a fourth field, `attribution`** — an array
  of `{board_image_id, label, license_type}` entries, one per bundled asset
  whose `Images::RedistributionLicense::Result#attribution_required?` is
  true. That predicate is only ever true for the `"cc by"` license family
  (`type.start_with?("cc by")`, inside the redistributable branch of
  `RedistributionLicense.for`) — it is unconditionally `false` for a user's
  own content, SpeakAnyWay/OpenAI-authored content, protected (proprietary
  symbol set), and untrusted (web-scraped) content, since those branches
  return early with `attribution_required: false`. `ObzPackager#summarize`
  flattens every board's attribution list into `summary["attribution"]`, and
  `#readme_text` adds a `README.txt` section naming each attributed image and
  its license type whenever that list is non-empty.
- **`Boards::ExportScope::MAX_BOARDS` (200) is the only board-count cap.**
  `Boards::PredictiveLinkSet.collect` (used for the single-board + linked-set
  export) is bounded by `max_depth` (`ExportScope::MAX_DEPTH`, 6) only — it
  has no count limit of its own, so a wide, shallow link graph relies
  entirely on `ExportScope` to keep the package bounded.
  `Boards::ObzPackager::MAX_BYTES` (200MB) is a second, independent cap on
  total package size, since a small number of boards can still carry large
  images.
- **`asset_mode: :inline` (the synchronous `GET /download_obf` path) has its
  own, separate caps.** `ObfExporter::MAX_INLINE_TILES` (200) is checked
  against the board's tile count up front, before any work starts.
  `MAX_INLINE_BYTES` (20MB) accumulates as each image's bytes are read and
  base64-encoded and is checked per-image inside `attach_asset`, so an export
  can still raise partway through a board on one oversized image. Either cap
  raises `Boards::ObfExporter::TooLarge`, which `BoardsController#download_obf`
  rescues into a **422** whose body's `export_package_url` points the caller
  at the async `.obz` path (`export_package`) instead. Neither cap applies to
  `asset_mode: :package` (the `.obz` path), which relies entirely on
  `ObzPackager::MAX_BYTES` above — and `MAX_INLINE_BYTES` itself only counts
  image bytes: audio base64-encoded for `:inline` sound entries is a known,
  accepted gap, not counted against it (audio is small relative to images).
- **`ObzPackager#write_assets`'s `MAX_BYTES` check is incremental, not
  post-hoc.** The running byte total is checked as each asset is read and
  written, raising `ObzPackager::TooLarge` as soon as the package would
  exceed 200MB rather than after the whole zip has already been built in
  memory — checking early is the entire point of the cap, since the goal is
  bounding memory pressure, not just refusing to upload an oversized file.
  Assets are deduplicated by zip path via a `seen` hash (the same doc can
  back tiles on several boards); a **failed** read is recorded in `seen` too
  (mapped to `nil`, then `seen.compact` strips it before the manifest is
  built), so a shared broken asset referenced by multiple boards is read —
  and its failure logged to `packaging_failures` — exactly once, not once
  per referencing board.
- **The `.obz` layout is dictated by `ObzImporter`, not chosen freely.**
  `spec/services/boards/obz_round_trip_spec.rb` is the contract between
  `ObzPackager` and `ObzImporter` — changing the manifest/paths layout in one
  without the other breaks that spec.
- **Tile audio is bundled into `.obz` packages** (`asset_mode: :package` and
  `:inline`; `:url` mode still emits only a `url:`/`audio_url` reference,
  unchanged). `ObfExporter#sound_entry` resolves the actual attachment
  backing each tile's sound — the tile's own custom recording
  (`current_audio_attachment`) if it has one, else the shared `Image`'s
  TTS/upload audio — and reads the real `content_type` off that attachment's
  blob instead of guessing. **Zip paths key on the resolved audio
  ATTACHMENT's id** (`sounds/<attachment_id>.<ext>`), not the tile's or
  `BoardImage`'s id, mirroring how image paths key on `doc.id`: two tiles
  that fall back to the same shared `Image` audio land on the same path,
  which is what lets `ObzPackager#write_assets`'s `seen`-hash dedupe collapse
  them into one zip entry instead of writing the same bytes twice under
  different tile ids. The OBF sound object's own `id:` field is a separate
  concern and stays per-tile (the `BoardImage` id) — an OBF-schema
  requirement (unique sound ids), not the zip path. **A known, accepted
  asymmetry:** `to_obf_sound_format` emits a sound entry whenever bundled
  bytes exist, but `to_obf_button_format` only emits a button's `sound_id`
  when the tile's cached `audio_url` column is present — so a sound could in
  theory be bundled with no button referencing it, if `audio_url` were stale
  relative to the actual attachment. Rare in practice: all three production
  call sites that attach tile audio keep `audio_url` in sync with the
  attachment. **No `RedistributionLicense`-style licensing gate exists for
  audio** — bundling is unconditional — because no code path today attaches
  third-party audio to `audio_files`; every attachment is either
  SpeakAnyWay's own Polly/OpenAI synthesis or the user's own
  recording/upload. **Import does not consume this.** `ObzImporter` /
  `Board.from_obf` still ignore `obf["sounds"]` entirely, so a
  round-tripped (export-then-reimport) package loses its bundled audio —
  this task was export-only; the import gap is separate and pre-existing,
  not newly introduced.
- **Known limitation: a packaging-time read failure can leave a dangling
  `path:` reference.** `ObfExporter#attach_asset` already rescues a read
  failure at OBF-build time and degrades that image to a `url:` reference.
  But `ObzPackager#write_assets` reads asset bytes again, later, when
  actually writing zip entries — at that point the board's `.obf` entry has
  already been written into the zip with a `path:` reference to the asset.
  If the read fails here (e.g. Active Storage says a blob is attached but
  the underlying S3 object is missing or corrupt), the failure is caught and
  recorded in `summary["packaging_failures"]` and `README.txt`, but the
  already-written `.obf` entry's `path:` reference is left dangling rather
  than rewritten to `url:`. A two-pass rewrite (verify every asset is
  readable before writing any `.obf` entry) would close this but was
  deliberately not built for this rare a failure mode — see the comment
  above `read_asset_bytes` in `app/services/boards/obz_packager.rb`.
- **Existence disclosure is now consistent 404 across all four export
  authorization surfaces.** `Api::BoardGroupsController#export_package` no
  longer reuses `authorize_board_group_read!` (which still renders 403,
  confirming existence, for its other callers, e.g. `#graph`) — it now
  inlines its own check (`board_group && (current_user&.admin? ||
  board_group.user_id == current_user&.id)`) and renders a generic 404 on
  failure, matching `Api::BoardsController#export_package`/`#download_obf`
  and `Api::BoardExportsController#show`/`#download`. Scoped to
  `export_package` only — every other `authorize_board_group_read!` caller
  is untouched and still returns 403.
- **`ObfExporter#call` batches its dominant per-tile queries**, though the
  benefit only lands for `asset_mode: :package` (the async `.obz` path — the
  actual volume driver, since `Boards::ExportScope::MAX_BOARDS` caps a
  single package at 200 boards); `asset_mode: :url` barely touches these
  paths to begin with, so it sees no real change. Three fixes:
  - `board.board_images` is now loaded with `.includes(:image, :board)`
    instead of a bare `.to_a`, avoiding a query per tile for its image and
    (for predictive-link buttons) the linked board.
  - Every tile's `predictive_board_id` is resolved in one
    `Board.where(id: predictive_ids).index_by(&:id)` call (`boards_by_id`)
    instead of one `Board.find`/`find_by` per linked tile, threaded into
    `BoardImage#to_obf_button_format(boards_by_id:)`.
  - The exporting user's `user_docs` are preloaded once into
    `@preloaded_user_docs` (grouped by `image_id`) and threaded through
    `BoardImage#export_doc(preloaded_user_docs:)` →
    `Image#display_doc(preloaded_user_docs:)`, replacing what was one
    `user_docs.includes(:doc).where(image_id: id)` query per tile.
    `display_doc`'s `preloaded_user_docs:` keyword defaults to `nil`, so its
    ~15 other callers are byte-identical. The preloaded path still sorts by
    **`UserDoc#updated_at`**, not `Doc#updated_at` (the field that would be
    the obvious/simpler sort key) — because `Doc` has no uniqueness
    constraint on `(user_id, image_id)` and the two timestamps can diverge
    in normal use, so switching sort keys would silently change which doc
    wins a tie.
  - `BoardImage#to_obf_image_format` also gained an optional `content_type:`
    keyword: when the exporter has already resolved a tile's doc via
    `export_doc` (which honors `preloaded_user_docs`), it passes that doc's
    real blob `content_type` straight through instead of falling back to
    `image.content_type`, which calls `Image#display_doc` again with no
    preload — a second, unbatched query. This is a correctness fix as much
    as a perf one: for a user with their own replacement doc for a shared
    library image, the declared `content_type` now matches the bytes
    actually bundled, rather than the shared `Image`'s default doc's type.
- **Export endpoints are rate-limited and refuse a second in-flight
  export.** Rack::Attack throttles `POST /api/boards/:id/export_package` and
  `POST /api/board_groups/:id/export_package` together under `export/user` —
  `RACK_ATTACK_EXPORT_LIMIT` (default 10) per `RACK_ATTACK_EXPORT_PERIOD`
  (default 3600s), ENV-tunable like the app's other throttles. Independently,
  both controllers check `current_user.board_exports.where(status: %w[queued
  processing]).exists?` before creating a new `BoardExport`, returning
  **409 `export_in_progress`** if one is already outstanding. **Known,
  accepted gap:** that guard is check-then-create with no DB-level lock (no
  unique index, no `SELECT ... FOR UPDATE`), so two genuinely simultaneous
  requests could both pass the check and both create a `BoardExport` — a
  rare, low-consequence race (worst case: two exports run instead of one),
  bounded by the rate limit above and accepted rather than fixed.
- **`GET /api/board_exports/:id/download` redirects instead of buffering.**
  It now `redirect_to`s the attachment's storage URL
  (`@board_export.file.url(disposition: "attachment", filename: ...)`,
  `allow_other_host: true`) rather than streaming the whole `.obz` (up to
  `ObzPackager::MAX_BYTES`, 200MB) through the Puma worker via `send_data`.
  `#show` and the 404-for-unowned-or-missing-export behavior are unchanged.
- **Known limitation: a cropped image's `source_type` does not reflect the
  crop's actual provenance.** When a user crops an image whose source was a
  proprietary symbol set (e.g. SymbolStix), the resulting crop gets
  `source_type: Doc::SOURCE_TYPE_USER` stamped on it — `RedistributionLicense`
  then treats it as user-owned and bundles it, even though the crop's
  provenance is actually proprietary. This is the same accepted "can't detect
  a user's own upload" limitation the ownership check already lives with, but
  differs in one respect: for a crop, provenance IS actually available (the
  parent `Image`/source `Doc`) — a future fix could trace a crop back to its
  source and inherit that `source_type` instead of stamping `User`
  unconditionally. Not fixed here; tracked as issue #555.

## Board deletion safety (warn + confirm)

`DELETE /api/boards/:id` is a **warn+confirm** flow. `Boards::UsageCheck`
(`app/services/boards/`) reports what still references the board: folder tiles
on other boards (`board_images.predictive_board_id`, self-links excluded),
communicator dashboards (`child_boards`), team shares (`team_boards`), and
whether it's a Board Builder root. When anything matches and the request lacks
`confirm=true`, destroy returns **409** `{ error: "board_in_use", message,
board: { id, name }, usage: { referencing_boards, communicators, teams,
builder_set } }` (counts exact, name lists capped at 10). Unreferenced boards
delete in one step as before.

- **Builder roots cascade the whole set.** A confirmed delete of a
  `builder_root` board routes through its builder BoardGroup
  (`Board#builder_board_group` → `group.destroy!`), so the #407 cascade
  destroys every member board instead of orphaning the hidden children. This
  routing lives **only in the controller** — a Board `before_destroy` that
  destroyed the group would recurse with the group's `destroy_all` of members.
  A root whose group is gone (legacy data) falls back to a plain destroy.
- **Cleanup on destroy.** Folder tiles pointing at the deleted board are
  nullified by the `predictive_board_images dependent: :nullify` association
  (the old manual loop in `#destroy` was redundant and only covered
  `board_type == "predictive"`). `docs.board_id` is nullified
  (`dependent: :nullify`; docs are user content owned via `documentable`).
  `BoardDestroyCleanupJob` (`app/sidekiq/`, enqueued `after_destroy`, rescue-
  wrapped so a Redis blip can't fail the destroy) scrubs the pointers
  `dependent:` can't reach: `users.editable_board_id`, the
  `dynamic_board_id`/`phrase_board_id` keys in users' and child_accounts'
  settings JSONB, and `Scenario` rows for the board. `word_events` keep their
  `board_id` deliberately (analytics history).
- **`orphan_template?`** (`ChildBoardsController`) also refuses to hard-delete
  a detached template that another board's folder tile still opens
  (`predictive_board_id` reference check) — detach-only in that case.
- Frontend companion: handle the 409 with a confirm dialog and re-send with
  `confirm=true` (special copy for builder roots — it deletes the whole set).

## Board Sets (BoardGroup) — user CRUD + limits

Board Sets (`BoardGroup`, user-facing name "Board Sets") are user-owned
collections of boards. CRUD is open to any signed-in user;
`predefined: true` sets stay admin-curated. Viewing is **public by link** —
`index`, `show`, `show_by_slug`, and `preset` keep
`skip_before_action :authenticate_token!`.

- **Owner-or-admin authorization.** Every mutating action in
  `API::BoardGroupsController` (`update`, `destroy`, `rearrange_boards`,
  `save_layout`, `remove_board`, `add_board`) routes through the private
  `authorize_board_group!` helper: admins always pass; everyone else is
  blocked (**HTTP 403** `"You don't have permission to modify this board
  set."`) unless they own the set *and* it isn't `predefined`. Before this
  work, `rearrange_boards`/`save_layout`/`remove_board` had **no** auth at all
  — any user could mutate anyone's set. `create` is open to all authed users.
- **Protected flags.** `board_group_params` strips `predefined` and `featured`
  for non-admins, so a regular user can't self-promote their set into the
  curated/featured pools.
- **Per-plan creation limits.** Mirrors the board-limit pattern.
  `User#board_group_limit` resolves from the plan hash by `plan_type` (Free 1,
  Basic 25, Pro 50; ENV-overridable via `FREE_/BASIC_/PRO_BOARD_GROUP_LIMIT`),
  with a `settings["board_group_limit"]` override. `User#countable_board_group_count`
  counts own non-predefined sets; `User#at_board_group_limit?` is the gate
  (admins exempt). `create` returns **HTTP 422** `{ error, limit, count }` at
  the cap. **Not 402** — 402 is reserved for credit exhaustion.
- **`add_board` route.** `POST /api/board_groups/:id/add_board/:board_id`
  (`BoardGroup#add_board` does the join + layout init). Beyond the owner-or-admin
  set check, the *board* must belong to the caller or be predefined/public.

## Responsive board layouts (sm/md derived from lg)

A board stores a per-tile `layout` for each screen size (`lg`/`md`/`sm`, plus
`xs`/`xxs` mirrors of `sm`). `lg` is the **authored** layout; md/sm are
**derived** from it so a board reads well on tablets and phones without ever
losing a tile.

- **Column counts — `Boards::ScreenColumns.derive(large_columns, screen)`** is
  the single source of truth: `md ≈ ⅔·lg`, `sm ≈ ⅓·lg`, rounded and clamped so
  `sm ≤ md ≤ lg` with a 2-column floor for phones. `Board#set_screen_sizes`
  (before_create) and `get_number_of_columns` (BoardsHelper) both derive md/sm
  from lg when not explicitly set; `Boards::LayoutRepacker` uses the same rule.
  The frontend mirrors it (`deriveColumns`/`resolveColumns` in
  `nativeLayoutMath`) so viewer, editor, and backend agree.
- **Tile reflow — `Boards::ScreenReflow.reflow!(board, screens:)`** rebuilds the
  md/sm (and xs/xxs) per-tile layouts from the **lg reading order** (sorted by lg
  y,x), width-aware row-major packed into each screen's column count, then
  resyncs `board.layout` via `LayoutRepacker.resync_board_layout!`. lg is never
  modified; every tile is placed (nothing dropped). This is distinct from
  `LayoutRepacker` (which only nudges overflow tiles back inside an existing
  grid — a data-repair net); reflow is the intentional responsive layout.
- **When it runs.** `Board#apply_layout!` calls `sync_derived_screen_layouts!`:
  editing **lg** reflows the non-customized md/sm; editing **md/sm** records that
  screen in `settings["custom_screen_layouts"]` so a later lg edit leaves the
  hand-arranged screen alone. `BuildBoardSetJob` reflows every board in a built
  set at the finalize chokepoint (before `generate_preview!`).
- **Backfill:** `rake board_layouts:reflow_sm_md` (dry-run by default;
  `DRY_RUN=false` to apply, `USER_ID=N` to scope, `KEEP_COLUMNS=true` to reflow
  without recomputing column counts) recomputes proportional md/sm columns and
  reflows existing boards, skipping fully-customized screens.


## Keyboard boards & action tiles

Predefined keyboard template boards ("ABC Keyboard" / "QWERTY Keyboard",
slugs `keyboard-abc` / `keyboard-qwerty`) are seeded by
`db/seeds/keyboard_boards.rb` (`rake keyboard_boards:seed`, idempotent):
`board_type: "keyboard"` (also `Board.keyboards` / `#keyboard?`), 26 letter
tiles + Space/Delete.

- **Tile behavior contract (frontend keys off this, not board_type):** letter
  tiles carry `board_images.data["tile_type"] == "letter"`; action tiles carry
  `data["tile_type"] == "action"` and `data["tile_action"] == "space" |
  "backspace"`. Future action tiles (e.g. play-a-video) add new `tile_action`
  string values plus an optional `data["action_params"]` object — keep
  `tile_action` a bare string. `data` already flows through
  `api_view_for_native_grid`, `BoardImage#api_view`, and `clone_with_images`
  (tiles are `dup`ed), so no serializer/clone changes are needed for new flags.
- **Publish gate:** the seeds create the boards `published: false` because
  frontends without keyboard support render Space/Delete as ordinary speakable
  word tiles. Flip `published: true` only after the frontend keyboard support
  deploys; re-running the seed never unpublishes.
- **Layouts:** authored identically for all screen sizes with equal column
  counts (6 ABC / 10 QWERTY), and `settings["custom_screen_layouts"] = ["md",
  "sm"]` so an lg edit doesn't reflow away the QWERTY stagger or wide space bar.
- Word-as-written playback needs no backend work: the frontend composes the
  string and uses the existing `POST /api/images/generate_audio`.
