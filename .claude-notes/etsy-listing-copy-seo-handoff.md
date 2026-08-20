# Handoff: Etsy listing copy SEO rules (Rails)

**Date:** 2026-08-20 · **Status:** implemented (all four work items)
**Full plan:** `../../drafts/etsy-listing-copy-seo-plan.md` (this doc is self-contained; the plan adds context)
**Related:** `.claude-notes/board-printables-etsy.md` — read it first, it owns the pipeline's invariants
**Issue:** none filed

## Why this exists

All 21 live SpeakAnyWay Etsy listings were analyzed on 2026-08-20 with views
normalized by true listing age (`original_creation_timestamp` — the API's `created`
field resets on renewal and is misleading).

Core-vocabulary boards run 6–8 views/day. Niche-occasion boards — haircut, potty,
travel, feelings, classroom, recess — run ~0. The top listing has the shop's weakest
description and only six images, and a 20-day-old core board with no video was
outpacing it. Age, video, and description quality do not explain the gap. The title's
leading phrase and the tag set do.

Seven listings were hand-rewritten that day and are now live. **This generator still
produces the old shape**, so the next printable published from the admin reintroduces
every defect. That is what this work fixes.

## Decisions (already made — don't re-litigate)

1. Titles **always** lead with the head term ("AAC"). **Superseded 2026-08-20, later the
   same day:** the board name does NOT trail as a qualifier — it folds into the head
   itself, right after "AAC", because Etsy's shop grid truncates a title around 34
   characters and "AAC Communication Board Printable, " alone is already 35. A trailing
   qualifier put every non-core listing's distinguishing word past the cut, so they read
   as identical while browsing — the same defect `Etsy::TagOverlap` exists to catch, one
   field over. `Etsy::TitlePrefixOverlap` now warns when two printables share their first
   34 characters, same contract as `TagOverlap`. The "fold into the head when the board
   name already names the product" branch is unaffected — that was never a qualifier.
2. Single-word tags are blocked in `normalize_tag` **and** removed from the pools.
   Rule-level enforcement was explicitly chosen so a future pool edit cannot
   reintroduce them.
3. Rails only. Do **not** touch `speakanyway-printables` — its generator has already
   diverged deliberately and has its own sync doc.
4. Tags say `nonverbal`; description prose keeps `nonspeaking`. Etsy tags are a search
   index, not a brand surface. This is an approved, deliberate split — do not
   "fix" the inconsistency.
5. `pecs alternative` gets a permanent top-up slot.

## Current state

### `app/services/etsy/copy_rules.rb`

`normalize_tag` (L66-72) enforces Etsy's character set and the 20-char cap, and rejects
all-small-word phrases. It does **not** enforce a minimum word count, so a one-word tag
passes cleanly.

`assemble_tags` (L129-151) is correct and was fixed in a prior pass — `topic` runs
second, capped at `TOPIC_TAG_MAX = 6` (L113). Preserve that order; the comment at
L118-124 explains what breaks if it moves back.

`pick_fitting_title` (L165+) takes a widest-first candidate ladder and requires the last
rung to always fit. Keep that contract.

### `app/services/etsy/listing_copy.rb` — where the defects are

```ruby
ALWAYS_ON_TAGS = ["aac", "printable", "digital download"].freeze   # L25
AUDIENCE_TAGS  = ["autism support", "slp", "classroom"].freeze     # L30
```

Five of thirteen slots, on every listing, spent on terms that compete with the entire
marketplace. `TOP_UP_TAGS` (L47-59) is otherwise good but carries `nonspeaking` (L52)
and has no `pecs alternative`.

`#title` (L139-175) builds:

```ruby
head = if names_product
  "#{base} AAC Printable"                                          # L149
else
  "#{base} AAC #{CopyRules.title_case_words(PRODUCT_HUMAN)} Printable"  # L151
end
```

`base` is the board name, so a board called "Recess" produces *"Recess AAC
Communication Board Printable, …"* — the exact shape that shipped at zero views. The
comment at L136-138 justifies leading with the board name over the brand name; that
reasoning is sound but incomplete, since it only holds when the board name is itself a
search term ("Core Words Board"), not when it's a niche noun ("Recess", "Haircut").

`PRODUCT_HUMAN = "communication board"` (L23) is correct — leave it.

### Reference: the seven approved live titles

These are the target shape. Match them.

```
AAC Communication Board Printable, Haircut and Salon Visits, 3-Board Autism Speech Therapy Set (Digital Download)
AAC Communication Board Printable, Potty Training 3-Board Visual Set for Autism and Speech Therapy (Digital Download)
AAC Communication Board Printable, Travel and Vacation 3-Board Set for Autism and Speech Therapy (Digital Download)
AAC Communication Board Printable, Feelings and Emotions 5-Board Set for Autism and Self Regulation (Digital Download)
AAC Communication Board Printable, Classroom and School 4-Board Set for Special Education (Digital Download)
AAC Communication Board Printable, Recess and Playground Set for School and Speech Therapy (Digital Download)
AAC Core Communication Board, 84-Word Core Vocabulary Printable for Speech Therapy and Aphasia (Digital Download)
```

## Work items

### 1. Block single-word tags in `normalize_tag`

`app/services/etsy/copy_rules.rb`, after the existing small-word check (L69):

```ruby
return nil if cleaned.split(" ").length < 2
```

Add a comment saying why: single-word tags compete with the whole marketplace and
measurably do not rank; five slots per listing were being burned this way.

This is a behavior change with real reach. `normalize_tag` is called by `topic_tags`
(L91, L102) and by `Etsy::Client#normalize_tags` (`app/services/etsy/client.rb` L247-249,
public), which is itself called from `Admin::BoardPrintablesController` L383 — so the
**admin hand-edit save path runs through it too**, not just generation. A one-word tag
typed by hand in the admin form will now be silently dropped. That is intended, but
know it before you're surprised by it.

It breaks existing specs. These are pinned assertions, not accidents — update each one
deliberately:

| File | Lines | What breaks |
|---|---|---|
| `spec/services/etsy/listing_copy_spec.rb` | **L131-139** | Exact-equality pin on the full 13-tag boilerplate array containing `"aac"`, `"printable"`, `"slp"`, `"classroom"`, `"nonspeaking"`. Fails against all three changes at once. **This is the intended-behavior pin — rewrite it in lockstep with the pool changes, don't patch around it.** |
| `spec/services/etsy/listing_copy_spec.rb` | L82-89 | Asserts 13 slots and `include("aac", "printable", …)` |
| `spec/services/etsy/copy_rules_spec.rb` | L131-133 | `topic_tags("core words / feelings")` expects `"feelings"` to survive — the only direct single-word-survives assertion |
| `spec/services/etsy/copy_rules_spec.rb` | L49-63, L65-77, L84-96, L100-111 | Four `assemble_tags` examples whose fixtures include single-word tags and assert exact arrays or a length of 13 |

### 2. Fix the pools

`app/services/etsy/listing_copy.rb`:

```ruby
ALWAYS_ON_TAGS = ["printable aac", "communication board", "low tech aac"].freeze
AUDIENCE_TAGS  = ["autism support", "slp resources", "classroom visuals"].freeze
```

`PRODUCT_TYPE_TAGS` is `[PRODUCT_HUMAN]` = `"communication board"`, which now duplicates
an always-on entry. `assemble_tags` dedups, so this is harmless at runtime — but resolve
it rather than leaving two sources of the same tag. Either drop it from `ALWAYS_ON_TAGS`
or make `PRODUCT_TYPE_TAGS` carry the secondary term. Note the existing comment at
L43-46 already reasons about this exact overlap; keep it truthful to whatever you choose.

In `TOP_UP_TAGS`: add `"pecs alternative"` near the top (highest buyer intent in the
pool), replace `"nonspeaking"` with `"nonverbal child"`, and remove `"slp resources"`
and `"classroom visuals"` if you moved them into `AUDIENCE_TAGS`.

Every tag must be ≤20 characters. `"pecs alternative"` is 16, `"nonverbal child"` is 15,
`"communication board"` is 19.

### 3. Head-term-first titles, board name folded into the head (implemented, corrected)

`app/services/etsy/listing_copy.rb#title`. This shipped in PR #737 with the board name
as a trailing qualifier (`"AAC Communication Board Printable, #{base}, …"`), which turned
out to break the shop grid: Etsy truncates a title around 34 characters there, and the
fixed head alone already eats 35, so every non-core listing rendered identically while
browsing. Corrected the same day — the board name now goes INSIDE the head, at
character 4:

```ruby
head = if names_product
  "AAC #{base}"                                                          # unchanged
else
  "AAC #{base} #{CopyRules.title_case_words(PRODUCT_HUMAN)} Printable"   # "AAC Recess Communication Board Printable"
end
```

`subject` is gone — the board name is always inside `head` now, in both branches, so it
is never repeated in the qualifier clause below. The qualifier clause carries only
`size_phrase` and `topic_phrase`. Keep the widest-first ladder and keep a
guaranteed-fitting last rung (`generic_head`, unchanged — the fixed phrase with no board
name at all) — `pick_fitting_title` truncates mid-word if every rung overflows, which has
already shipped a listing titled `"… Printable for Speech The (Digital Download)"`. A
board name long enough to overflow even the bare `head` falls all the way to
`generic_head`, which drops the board name and the tail — that's an accepted trade-off,
not a bug: a title that can't fit the board name at all is better generic than truncated
mid-word.

`app/services/etsy/title_prefix_overlap.rb` is the admin advisory that would have caught
the trailing-qualifier defect: it warns when two printables' titles share their first 34
characters, same WARN-never-block contract as `Etsy::TagOverlap`. Wired into
`Admin::BoardPrintablesController#show` as `@title_prefix_overlap` and rendered in
`_tag_overlap.html.erb` alongside the tag-overlap card.

Watch the ampersand: `tail` is `"for Speech Therapy & Autism"` and Etsy 400s on a second
`&`. `enforce_title_rules` rewrites later ones to "and", so this is handled — but if you
add another `&` anywhere, know that's why the first survives and the rest don't.

### 4. Extend the admin advisory panel

`app/services/etsy/tag_overlap.rb` already warns on ≥10-of-13 overlap and renders via
`app/views/admin/board_printables/_tag_overlap.html.erb`. Add three checks in the same
panel: tag count below 13, any single-word tag present, and head term absent from the
title's first 40 characters. Advisory only — never block a publish.

## Testing

Specs live in `spec/services/etsy/`. Run at minimum:

```
bundle exec rspec spec/services/etsy/copy_rules_spec.rb \
                  spec/services/etsy/listing_copy_spec.rb \
                  spec/services/etsy/tag_overlap_spec.rb
```

Prove these cases:

| Case | Expected |
|---|---|
| `normalize_tag("aac")` | `nil` |
| `normalize_tag("printable aac")` | `"printable aac"` |
| `normalize_tag("a communication board that talks")` | `nil` (over 20 chars, unchanged behavior) |
| Board named "Recess", no topic | title starts `"AAC Communication Board Printable,"` |
| Board named "Core Words Board" | title starts `"AAC Core Words Board"` — not repeated |
| Any generated printable | exactly 13 tags, none single-word, none over 20 chars |
| Two different boards, different topics | tag sets differ by ≥4 tags (the `MIN_TOPIC_TAGS` premise) |
| Long board name, no topic | title fits 140 including suffix, not truncated mid-word |

Also run `bundle exec rspec spec/requests/admin/board_printables_spec.rb` — the admin
show page renders generated copy and the advisory panel, and its save path calls
`Etsy::Client#normalize_tags`.

## Deploy notes

No migrations. No new ENV vars. No API contract change. Copy generation only, confined
to `app/services/etsy/`.

**Do not run `regenerate_listing_copy!` against these seven listings** — they were
hand-tuned and approved on 2026-08-20, and regenerating overwrites `listing_copy`:

```
4554491916  4557544635  4556388009  4554121725  4554595592  4559346650  4556507027
```

`BoardPrintable#regenerate_listing_copy!` (`app/models/board_printable.rb` L473-479) does
`existing.merge(generated)` — so it overwrites title, summary, description and tags, while
`price_cents` and any other non-generated key (the TPT overrides named in the comment at
L470-472) survive. New printables only.

## Wrap-up

Git workflow lives in the **workspace-root** `CLAUDE.md` and the global instructions, not
in this repo's `CLAUDE.md` — feature branch in a worktree cut from `origin/main`, never
commit to `main`. There is no `bin/install-hooks` in this repo.

**`.claude-notes/` is gitignored here** (repo CLAUDE.md L8-10). To commit this doc in the
PR you must `git add -f .claude-notes/etsy-listing-copy-seo-handoff.md` — a plain
`git add` silently skips it and the doc dies with the session.

Open the PR and stop — never merge.
