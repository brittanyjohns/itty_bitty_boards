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

**`Images::RedistributionLicense.for(doc)`** → `Result(bundlable:, type:,
attribution_required:, reason:)`.

This answers a *different question* from `CommercialLicense`. That service asks
"may this appear in a product we sell?" and therefore excludes `NC`
(non-commercial) and `ND` (no-derivatives). But NC and ND generally **do**
permit redistribution — NC forbids commercial use, ND forbids derivatives.
Reusing it verbatim would silently drop CC BY-NC images from a user's personal
export, which users would reasonably report as a bug.

Rules, evaluated in order, failing closed like the original:

1. `false` if `protected_symbol` — catches SymbolStix / PCS
2. `true` if `source_type == "OpenAI"` — we generated it
3. `false` if `source_type` is untrusted (`nil`, `""`, `"GoogleSearch"`)
4. `true` if the normalized type is a recognized CC / CC0 / public-domain
   family member, **including `-nc`, `-nd` and `-sa` variants**
5. `false` otherwise

`reason` is a short human string; it is what the UI warning and the packaged
`README.txt` surface.

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

Per image, via `RedistributionLicense.for(display_doc)`:

- **bundlable** → bytes written into the zip, referenced by `path:`, `url:`
  omitted
- **not bundlable** → `url:` reference only, recorded as an omission with its
  `reason`

Board `license` becomes **derived** rather than hard-coded:

| Contents | Emitted license |
|---|---|
| all bundled assets owned / CC0 / public domain | `{"type": "CC BY-SA 4.0", "url": …}` |
| mixed recognized licenses | most restrictive recognized type + attribution list |
| **any omissions** | `{"type": "private"}` (the `obf_shell` default) + `README.txt` |

**Decision:** any omission downgrades the whole board to `private`. This is
conservative — one stray proprietary image marks the board private even if
everything else is ours.

**Recorded alternative:** keep the derived license and note omissions only in
the `README.txt`. This is a one-line change in `ObfExporter` if the conservative
rule proves too heavy-handed in practice. Flagged to Brittany at design time;
she approved the conservative default.

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
- `Board#license` stops hard-coding CC BY-SA 4.0 (see above).
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
  this board + N linked boards). Shows a warning line when some images will be
  url-only for licensing reasons. Shows async progress then a download link for
  `.obz`, and the failure state.
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

- `spec/services/images/redistribution_license_spec.rb` — matrix over OpenAI,
  `protected_symbol`, CC BY, CC BY-NC, CC BY-SA, CC BY-ND, nil source,
  GoogleSearch, ObfImport with a declared license, and the ambiguous
  multi-symbol case
- `spec/services/boards/obf_exporter_spec.rb` — grid `order` ids are strings and
  match button ids; the three asset modes; `load_board` carries both `path` and
  `id`; derived license per contents; position fallback on blank layout
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

None. The one judgment call (omissions downgrading a board to `private`) is
decided above, with the alternative recorded for an easy reversal.
