# Library image dedupe + admin art curation

Covers `Images::DuplicateScanner`, `ImageMergeBatch` / `ImageMerge`,
`ImageMergeBatchJob` / `ImageMergeJob`, `lib/tasks/library_images.rake`, and
`API::Admin::ImagesController`.

## The problem

`images` rows accumulate duplicates. The seeded library carries several rows for
the same word — most from historical import and generation paths that used a
case-sensitive `find_by(label:)` and minted a blank twin on a miss. Measured on
a dev snapshot of 7,366 images: **6,087 library images, 591 duplicate groups,
1,280 redundant rows**, with the largest group at 72 (`top page`).

The damage is not just clutter. 1,028 library images have no docs at all and
1,508 have a blank `src_url`, and 127 duplicate groups are **mixed** — some rows
have art, some don't. A tile that resolves to the blank twin shows nothing while
the curated art sits one row away.

## The two-step shape, and why

Merging destroys `Image` rows and **`images` has no soft-delete** (adding a
`deleted_at` would have to be honoured by every scope on the model). So the
expensive half is separated from the decision, exactly like `AdminBoardBuild`:

1. `library_images:scan` runs `Images::DuplicateScanner` — a **pure read** — and
   stores the result as a `planned` `ImageMergeBatch`. It writes no image data.
   Note it never calls `Boards::ImageResolver.resolve`, which mints a blank
   `Image` for an unmatched label; a preview must not create rows.
2. `library_images:apply[ID]` enqueues `ImageMergeBatchJob`, which fans out one
   `ImageMergeJob` per group.

There is deliberately **no flag that does both**.

## Scope — never a user's image

`Images::DuplicateScanner.candidate_scope` is `Image.default_public`
(`user_id IN [nil, DEFAULT_ADMIN_ID]`, not private) minus
`EXCLUDED_IMAGE_TYPES` (`menu`/`Menu`/`SampleVoice`/`OpenaiPrompt`/`Scenario` —
not interchangeable library symbols). `ImageMergeJob` re-asserts membership in
that same scope immediately before each destroy, so a row that became a user's
or went private between scan and run is skipped, not merged.

## Grouping is (label, language, part_of_speech) — all three matter

`part_of_speech` is load-bearing: `Images::PromptBuilder` disambiguates
homographs by it, so `can` (verb) and `can` (noun) are *different pictures by
design*. 158 groups mix it. Grouping on label alone silently collapses them.

## Survivor: most docs, lowest id

Deliberately the same ordering as `Boards::ImageResolver.best_arted`, which is
already the codebase's answer to "which Image is canonical for this label". The
dedupe feeds that rule rather than competing with it.

## What a merge must carry across — the traps

`Image.destroy_duplicate_images` (the console method this replaces) missed two
of these, each measurable on the dev snapshot:

| Association | Trap | Count at risk |
|---|---|---|
| `predictive_boards` | `has_many … as: :parent, dependent: :destroy` — destroying the loser **destroys real boards**. Reparent first, with `update_all` so `Board#sync_user_parent` can't re-point an `Image` parent at a `User`. | 162 boards |
| `user_docs` | Keyed by BOTH `doc_id` and `image_id`. The docs move; without repointing `image_id` a user's saved picture choice silently detaches, because `Image#display_doc` looks it up by `image_id`. | 1,810 rows |
| `docs` | Must move through **`Doc.unscoped`** — `Doc` carries `default_scope { where(deleted_at: nil) }`, so both the association read AND `dependent: :destroy` skip soft-deleted rows and would orphan them. | — |
| `board_images` | Only `image_id` moves. `display_image_url` is per-tile user content and stays byte-identical, **including `""`**, the hide-pictures marker. | 12,795 tiles |

Tiles left pointing at art that died with the loser are repaired afterwards by
`Images::TileArtFanout` with `repair_dead: true` — the only mode that may cross
ownership, because a URL that no longer resolves is broken for its owner too.

## Idempotency and the kill switch

The unique index on `(image_merge_batch_id, group_index)` is the idempotency
key: a replayed `ImageMergeJob` finds its ledger row and returns. Every job
reads `batch.status` first and no-ops unless `running`, so
`library_images:pause[ID]` stops an in-flight run without draining the queue.

`ImageMerge` is the ledger — a jsonb snapshot of each destroyed row plus the ids
that moved. Since the rows are really gone, this is the only way to diagnose or
hand-reverse a bad merge.

## Queue

`maintenance`, priority 6 — below `varients`. Per the "usage must never break"
invariant, bulk housekeeping over thousands of rows must never starve `audio`
(priority 2) or tile rendering.

## Admin curation surface

`API::Admin::ImagesController` (`/api/admin/images/:id`) is the deliberate way
to pin the library default and to permanently remove a doc — things the app
could previously only do as a side effect of a user-shaped action.

**The actor is `current_admin`, never `current_user`.**
`API::Admin::ApplicationController` descends from the **top-level**
`ApplicationController` (not `API::ApplicationController`), so `current_user`
resolves to Devise's session helper and is `nil` for a token-authenticated
request — silently turning every `actor:` into "no actor", which fails
`Image#set_library_default_doc!`'s `can_edit?` gate and un-scopes the fan-out.

Setting the default moves **both halves**: `docs.current` (what a viewer with no
pick of their own resolves through) and `images.src_url` (what
`BoardImage#set_defaults` snapshots onto every FUTURE tile). Clearing resolves
`src_url` to the next doc rather than nil-ing it — a blank is silently refilled
by `before_save :update_src_url` on the next unrelated save, re-firing the
cascade from a surprising place.

Frontend: `LibraryDefaultManager`, mounted on the already-admin-gated
`/images/:id/edit`.

## Rake

```bash
bin/rails library_images:scan                 # writes nothing; prints a batch id
bin/rails library_images:scan LABEL=food LIMIT=25
bin/rails 'library_images:show[12]'           # review the plan + progress
bin/rails 'library_images:apply[12]'          # enqueue the fan-out
bin/rails 'library_images:pause[12]'
bin/rails library_images:default_health       # no docs / none current / MULTIPLE current / blank src_url
```
