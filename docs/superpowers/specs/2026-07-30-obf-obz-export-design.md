# OBF / OBZ export — finish the half-built path, then package sets

**Date:** 2026-07-30
**Status:** approved, ready for implementation planning
**Repos touched:** `itty_bitty_boards` (most of it), `itty-bitty-frontend` (one modal + one action)

## Problem

SpeakAnyWay imports Open Board Format fully but cannot export it. Users — SLPs
especially — have no way to take a board they authored here to another AAC app.

Export is not greenfield. It is **half-built and currently dead code**:

| Piece | State |
|---|---|
| `BoardsHelper#to_obf` (mixed into `Board`) | exists, builds a single-board OBF hash |
| `BoardImage#to_obf_{image,sound,button}_format` | exists |
| `GET /api/boards/:id/download_obf` route | exists |
| `Api::BoardsController#download_obf` | exists, sends `filename: "board.obf"` |
| `downloadObf()` in `src/data/boards.ts` | exists, **zero callers** |
| Any UI | **none** |
| Any OBZ (multi-board zip) export | **none** |

So the work is: correct what's there, add OBZ packaging on top, and surface it.

### What is actually wrong with the existing path

1. **No OBZ at all.** No zip packaging, no `manifest.json`, no multi-board
   export. `rubyzip` is only a *transitive* dependency, yet `obz_importer.rb`
   already does `require "zip"` — fragile.
2. **Assets are emitted as remote `url:` only.** No inlined `data:`, no
   zip-relative `path:`. A receiving app gets hotlinks that may 404, may need
   auth, or may be silently dropped. This is precisely the complaint people
   have about OBZ exports in the wild.
3. **`Board#license` hard-codes `CC BY-SA 4.0` for every board**
   (`app/models/board.rb:579`). Meanwhile `ObzImporter` deliberately records
   `BoardGroup.settings["imported_from_obf"]` with `include_images` and a
   license acknowledgment, *because imported symbol sets (SymbolStix, PCS) are
   proprietary*. Exporting those binaries under a CC BY-SA stamp the board
   never had would be a license misstatement. Export is the mirror-image risk
   of import — here SpeakAnyWay is the party redistributing.
4. **Grid/button id type mismatch.** `format_grid` emits `order` cells as
   integers (`cell["i"].to_i`) while buttons emit `id` as strings. Our own
   importer coerces both via `normalize_all_ids!`, so it round-trips *with
   itself*, but a spec-strict third-party importer may fail to match them.
5. **`load_board` emits only `id:`, never `path:`.** Most apps resolve OBZ
   links by path.
6. `format_grid` reads `large_screen_columns` raw (bypassing
   `get_number_of_columns`'s fallback) and has no handling for a blank or
   invalid `layout`.

## Scope

Three export entry points:

- **single board → `.obf`** (assets inlined as base64)
- **BoardGroup → `.obz`** (the natural inverse of import, which already lands a
  `.obz` into a BoardGroup)
- **any board + its linked subtree → `.obz`**, walked live over
  `BoardImage#predictive_board_id`

### Rejected: auto-creating a BoardGroup per linked board

Considered and rejected. It would have made "export a board and its children"
fall out of the BoardGroup path for free, but:

- **`BoardGroup` *is* the user-facing "Board Set."** It has a `name`, `slug`,
  `public_url`, `featured`, a pinned cover image and its own grid layout, and it
  renders on `Home.tsx`, `BoardGroupsScreen`, `PresetBoardGroupsScreen`.
  Auto-creating one per linked board floods those lists with machine-made sets
  the user never authored, each with a slug and a public URL.
- **The auto-delete half is dangerous.** `destroy_member_boards_if_builder`
  (`app/models/board_group.rb:83`) **destroys the member boards** when
  `builder: true`. A "delete the group when the last link is removed" rule is
  one bug away from cascading into destroying a user's boards.
- **The write paths are scattered.** `predictive_board_id` is set in
  `ObzImporter`, `CloneBoardJob`, `BuildBoardSetJob` (several places), the
  board_images controller, and a `BoardImage` callback that *nulls it out* when
  the target is missing. Every one would need the lifecycle hook; any miss is
  silent drift.
- **Shape mismatch.** A BoardGroup is a flat collection with one grid layout; a
  predictive-link tree is a navigation graph with cycles and targets that can
  live in other groups or other users' boards. A board can belong to many
  groups. Neither faithfully represents the other.

It is also unnecessary: `Boards::PredictiveLinkSet.collect` already does the
walk. Export resolves scope **at request time** — no persistence, no lifecycle,
no cleanup risk — and it works on boards that belong to no group at all.

## Architecture

### Reuse, don't rebuild

Four primitives already carry most of the weight:

| Existing | Role in export |
|---|---|
| `Images::CommercialLicense` | Its `resolve_license` / `normalize_type` internals already handle `protected_symbol` and ambiguous multi-symbol label matches. Extracted for reuse. |
| `Boards::PredictiveLinkSet.collect(root, max_depth:, exclude:)` | Cycle-safe, depth-bounded, root-first BFS. Its `exclude:` callable is exactly the hook for vetoing boards the requesting user cannot read. |
| `ObzImporter` | Defines the manifest/path format we must emit to guarantee round-trip. |
| `BoardScreenshotImport` | The `status` + `has_one_attached` polling pattern the frontend already knows. |

### New backend units

Each has one job and is independently testable.

**`Images::LicenseResolution`** — `resolve_license` and `normalize_type` lifted
verbatim out of `CommercialLicense` so there is exactly one place that knows how
to read a license off a `Doc` (including the OpenSymbol indirection, where the
license lives on the symbol row rather than the doc). No behavior change;
`spec/services/images/commercial_license_spec.rb` staying green is the guard.

**`Images::RedistributionLicense.for(doc, exporting_user:)`** →
`Result(bundlable:, type:, attribution_required:, owned_by_user:, reason:)`.

### This is a user-content feature, not a commercial one

`CommercialLicense` asks **"may SpeakAnyWay sell a product containing this?"**
`RedistributionLicense` asks **"may this user export their own board?"** These
are different questions with different answers, in both directions:

- `CommercialLicense` excludes `NC` and `ND` licenses. But NC forbids
  *commercial use* and ND forbids *derivatives* — both generally **permit**
  redistribution. Excluding them would drop perfectly exportable images.
- `CommercialLicense` treats `source_type` of `nil` / `""` as untrusted, because
  unknown provenance is a legal risk *to SpeakAnyWay when selling*. **That is
  the wrong test for export**, and dangerously so — see below.

**The critical case: user uploads have `source_type: nil`.** The permitted params
in `Api::ImagesController` are
`docs: [:id, :user_id, :image, :documentable_id, :documentable_type, :processed, :_destroy]`
— `source_type` is not among them. `#create`, `#add_doc` and
`attach_doc_to_image` all create docs with no source type. So a naive
"untrusted `nil` → don't bundle" rule would **exclude every photo a user
uploaded themselves** — the parent's photo of grandma, the picture of the
child's actual cup. That is the most personal and most important content on the
board, and it must always export.

So the predicate keys on **ownership first, license second**. License only ever
gates *third-party library* content. A user's own content is theirs; its license
is not ours to evaluate.

Rules, evaluated in this order:

1. `false` if `protected_symbol` — SymbolStix / PCS. Checked *first*: a
   proprietary symbol does not become redistributable by being attached to a
   user's image.
2. `true` if the content is **the exporting user's own** — `doc.user_id ==
   exporting_user.id`, or the parent `Image.user_id == exporting_user.id`.
   License is irrelevant here; set `owned_by_user: true`.
3. `true` if `source_type == "OpenAI"` — generated by us.
4. `true` if the parent `Image.user_id == User::DEFAULT_ADMIN_ID` and it is not
   protected — SpeakAnyWay's own library content.
5. For third-party library content (`OpenSymbol`, `ObfImport`): `true` if the
   resolved license is a recognized CC / CC0 / public-domain family member,
   **including `-nc`, `-nd` and `-sa` variants**.
6. `false` if `source_type == "GoogleSearch"` — scraped from the web. Not the
   user's content and carrying no license, so it stays a `url:` reference.
7. `false` otherwise.

`reason` is a short human string; it is what the UI warning and the packaged
`README.txt` surface.

**Known limitation, accepted:** if a user manually uploads a proprietary symbol
file, we cannot detect it — `protected_symbol` only resolves through
`matching_open_symbols` for `OpenSymbol`-sourced docs, and a bare upload has no
provenance to check. Rule 2 will bundle it. The user is the party who uploaded
their own file; treating their uploads as theirs is the same position any
file-hosting service takes. Blocking user uploads to guard against this would
break the feature's main purpose.

**`Boards::ObfExporter`** — builds one board's OBF hash. Takes
`asset_mode:` — `:inline` (base64 `data:`), `:package` (zip-relative `path:`),
or `:url`. Absorbs and retires `BoardsHelper#to_obf`.

**`Boards::ObzPackager`** — takes ordered boards + root and writes the zip.

**`Boards::ExportScope`** — resolves a request into
`{ boards:, root:, skipped_boards: }`, either from `BoardGroup#boards` or from
`PredictiveLinkSet.collect`, passing an `exclude:` that vetoes unreadable
boards.

Two distinct kinds of omission flow into the audit stamp, and the code keeps them
separate:

- **skipped boards** — produced by `ExportScope` (unreadable, or past the depth
  or board-count cap)
- **skipped assets** — produced by `ObfExporter` per image/sound (not
  redistributable, or the blob could not be read)

**`BoardExport`** (+ migration) — `status`
(`queued` / `processing` / `completed` / `failed`), `has_one_attached :file`,
`belongs_to :user`, polymorphic `exportable` (Board or BoardGroup), `settings`
jsonb holding the audit stamp.

**`ExportBoardPackageJob`** — Sidekiq; builds the package and attaches it.

**Gemfile** — add `gem "rubyzip"` explicitly.

### Delivery

| Export | Path | Why |
|---|---|---|
| single board `.obf` | synchronous `send_data` | ~24–48 tiles ≈ 1–2 MB inlined. Fast enough; no infrastructure needed. |
| `.obz` | `BoardExport` + Sidekiq + polling | A group or subtree can reach hundreds of boards and hundreds of tiles — tens of seconds of S3 reads plus zipping, which would time out behind the load balancer. |

Note on caps: `PredictiveLinkSet.collect` is bounded by `max_depth` **only** — it
has no board-count cap (the `MAX_BOARDS = 500` constant belongs to
`SetGraphBuilder`, a different service). `ExportScope` must therefore impose its
own board-count cap in addition to passing `max_depth:`, or a wide shallow graph
could produce an unbounded package.

Images resolve through `Doc` → ActiveStorage on S3 (public bucket), so bytes are
read from the blob directly rather than over HTTP.

### OBZ layout

Deliberately mirrors what `ObzImporter` reads, so round-trip is structural
rather than hopeful.

```
manifest.json
boards/<board-id>.obf
images/<doc-id>.<ext>
sounds/<board-image-id>.aac
README.txt          # written only when assets were omitted
```

```json
{
  "format": "open-board-0.1",
  "root": "boards/123.obf",
  "paths": {
    "boards": { "123": "boards/123.obf" },
    "images": { "456": "images/456.png" },
    "sounds": { "789": "sounds/789.aac" }
  }
}
```

`ObzImporter` reads `manifest["root"]` and `manifest.dig("paths", "boards")`,
resolves paths relative to the manifest directory, and falls back to guessing a
root — all satisfied by this shape.

## Licensing behavior

**These are two independent decisions.** An earlier draft of this spec coupled
them, which made the `private` license type read as a penalty for having
excluded images. It is not. Bundling decides whether bytes go in the package;
the license type is a declaration about what the package contains.

### Decision 1 — bundling, per asset

Via `RedistributionLicense.for(display_doc, exporting_user:)`:

- **bundlable** → bytes written into the package, referenced by `path:`, `url:`
  omitted
- **not bundlable** → `url:` reference only, recorded as a skipped asset with
  its `reason`

For an ordinary user exporting their own board, the expected outcome is that
**everything bundles**: their uploads (rule 2), images we generated for them
(rule 3), and our library symbols (rules 4–5). Skips should be the exception —
essentially only proprietary symbol sets that arrived via import, and scraped
GoogleSearch images.

### Decision 2 — the board's declared `license`

`Board#license` stops hard-coding `CC BY-SA 4.0`. Derived instead:

| Contents | Emitted license | Why |
|---|---|---|
| any content owned by the exporting user | `{"type": "private"}` | Honest. SpeakAnyWay has no standing to license a user's own photos under CC BY-SA on their behalf. |
| entirely SpeakAnyWay / predefined content that is ours, CC0 or public domain | `{"type": "CC BY-SA 4.0", "url": …}` | The current default — now actually true when emitted. |
| third-party CC content | most restrictive recognized type + attribution list | Passes through the real obligations. |

`private` here is the `obf_shell` default and means "not offered under an open
license" — it does **not** mean assets were withheld. A board full of a family's
own photos is fully bundled *and* correctly marked `private`.

Anything not bundled is listed in `README.txt` with its reason, independently of
which license type was declared.

### Audit stamp

`BoardExport.settings["exported_to_obf"]`, mirroring the shape of
`imported_from_obf`: bundled asset count, skipped asset ids with reasons,
skipped board ids with reasons, resolved license summary, exporting user id,
timestamp.

## Error handling — degrade, never fail the whole export

| Condition | Behavior |
|---|---|
| blank / invalid `layout` | fall back to position-ordered grid |
| blob missing, S3 read fails | degrade that asset to `url:`, record a skipped asset, continue |
| linked board the user cannot read | vetoed via `PredictiveLinkSet`'s `exclude:`, recorded as a skipped board |
| cycles | `PredictiveLinkSet`'s visited set |
| runaway depth or breadth | `max_depth:` plus `ExportScope`'s own board-count cap; excess recorded as skipped boards |
| package exceeds size cap | fail with an explicit message, not a timeout |
| job raises | `status: "failed"` + message surfaced in the modal |

A single bad image must never cost the user their whole export.

## Fixes to existing code

- `format_grid` emits `order` cell ids as **strings**, matching button `id`s.
  Safe: `format_grid` has exactly one caller (`to_obf`), and
  `ObzImporter.normalize_all_ids!` coerces both, so there is no round-trip
  regression.
- `format_grid` falls back to position-ordering on blank/invalid `layout`, and
  uses `get_number_of_columns("lg")` instead of raw `large_screen_columns`.
- `Board#license` stops hard-coding CC BY-SA 4.0 and is derived from contents
  (see "Licensing behavior" above). Note it must become
  `license(exporting_user)` — the correct answer depends on who is exporting,
  since ownership is what distinguishes `private` from an open license.
- `to_obf_button_format` emits `load_board.path` alongside `id` in package mode.
- `download_obf` sends a real filename (`<board-name>.obf`, parameterized)
  instead of the literal `"board.obf"`.

`Board#license` changing is technically visible in any existing `.obf`
download — but `downloadObf` has zero callers, so nothing in production is
affected.

## Frontend

- `src/data/boards.ts` — fix `downloadObf` (currently returns a raw `Response`
  with no error handling); add `exportBoardPackage` and `getBoardExport`.
- `src/components/boards/ExportBoardModal.tsx` — new, mirroring
  `DownloadPdfOptionsModal`. Offers format (`.obf` single board / `.obz`
  package) and, when the board has predictive links, scope (this board only /
  this board + N linked boards). Shows async progress then a download link for
  `.obz`, and the failure state. A warning line appears **only** when some
  images will be url-only for licensing reasons — for a user's own board this
  should normally be absent, and its presence in the common case is a signal the
  bundling rules have regressed.
- `src/components/boards/BoardEditorHeader.tsx` — add an Export item to the
  existing action list, next to Download PDF (this component already owns
  `downloadPdf` and `DownloadPdfOptionsModal`).
- Board Set pages (`ViewBoardSet.tsx`, `EditBoardSetScreen.tsx`) — Export
  button going straight to `.obz`.
- i18n: `src/locales/en.json` and `es.json`.

## Testing

The load-bearing test is a **round-trip spec**: export a BoardGroup, feed the
resulting bytes straight back into `ObzImporter`, and assert board count, tile
labels, grid positions and `predictive_board_id` links all survive. That
exercises both halves against each other and is the strongest available
guarantee of spec correctness.

Backend (RSpec):

- `spec/services/images/redistribution_license_spec.rb` — the matrix. The
  **highest-value case is a user-uploaded doc with `source_type: nil` owned by
  the exporting user, which MUST be bundlable** — that is the regression guard
  against reintroducing `CommercialLicense`'s treatment of `nil`. Then: a
  `nil`-source doc owned by a *different* user (not bundlable), OpenAI,
  `protected_symbol` (including one attached to a user-owned image, to pin the
  rule ordering), admin-owned library content, CC BY, CC BY-NC, CC BY-SA,
  CC BY-ND, GoogleSearch, ObfImport with a declared license, and the ambiguous
  multi-symbol case.
- `spec/services/boards/obf_exporter_spec.rb` — grid `order` ids are strings and
  match button ids; the three asset modes; `load_board` carries both `path` and
  `id`; position fallback on blank layout; and the two license decisions kept
  independent — a board of user-owned uploads bundles **every** asset *and*
  declares `private`
- `spec/services/boards/obz_packager_spec.rb` — manifest shape, entry paths,
  `README.txt` present only when assets were omitted
- `spec/services/boards/export_scope_spec.rb` — group vs subtree resolution,
  cycle safety, unauthorized-board veto
- `spec/services/boards/obz_round_trip_spec.rb` — the round-trip above
- `spec/requests/api/board_exports_spec.rb` — auth, status polling, download,
  failure state
- `spec/services/images/commercial_license_spec.rb` — must stay green,
  unchanged, as the extraction guard

Frontend (Vitest):

- `ExportBoardModal.test.tsx` — format/scope options, licensing warning, polling
  through to a download link, failure state

## Implementation sequence

Five PRs, each independently reviewable.

1. **Licensing primitive** — extract `Images::LicenseResolution`, add
   `Images::RedistributionLicense` + specs. Zero behavior change anywhere.
2. **Single board `.obf`** — `Boards::ObfExporter`, the `format_grid` and
   `Board#license` fixes, a working `download_obf`, retire
   `BoardsHelper#to_obf`.
3. **`.obz` + async** — `rubyzip` in the Gemfile, `ObzPackager`, `ExportScope`,
   `BoardExport` model + migration, `ExportBoardPackageJob`, endpoints, the
   round-trip spec.
4. **UI** — `ExportBoardModal`, the `BoardEditorHeader` action, the Board Set
   button, api client functions, i18n.
5. **Docs** — help-center article, `CHANGELOG.md` entries in both repos, notes
   in the repo `CLAUDE.md` / `.claude-notes/`.

## Open questions

None.

## Revision note

The first draft of this spec derived the export gate too directly from
`Images::CommercialLicense`, inheriting its rule that a `source_type` of `nil`
is untrusted. Because user-uploaded docs are created without a `source_type`,
that would have excluded users' own photos from their own exports — the exact
opposite of the feature's purpose. Corrected above: the predicate now keys on
ownership first and applies license rules only to third-party library content,
and the bundling decision is fully decoupled from the declared license type.
