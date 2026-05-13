# Build Plan — `/free-printable-aac-boards` (revised)

*Revised after deep-diving the existing frontend + backend. The original
plan assumed we were building from scratch; we're not — most of the
infrastructure already exists.*

---

## What I found that changes the plan

### 1. The PDF endpoint is already public ✅
`API::BoardsController` explicitly skips auth for the `pdf` action:

```ruby
skip_before_action :authenticate_token!, only: %i[ index predictive_image_board show public_boards public_menu_boards common_boards pdf ]
```

→ **"Logged-out PDF download" is not an open question. It works today.**

The frontend `downloadBoardPdf` ([src/data/boards.ts:317](itty-bitty-frontend/src/data/boards.ts:317)) does send auth headers, but the backend ignores missing tokens for `pdf`. So in practice it already works for anonymous users — just a tiny code smell to clean up.

### 2. "Public boards" is a real, working system ✅
`Board.public_boards` scope = `admin-owned + predefined + published`. There's already an existing pool of admin-curated, publicly-viewable, downloadable boards. The questions is **how many are teacher-relevant**, not whether the system exists.

### 3. A taxonomy of teacher-relevant tags already exists ✅
[src/data/constants.ts](itty-bitty-frontend/src/data/constants.ts) defines `SUGGESTED_BOARD_TAGS` — these are already teacher-relevant:
- `school`, `home`, `visual schedule`, `daily routine`
- `choice board`, `first-then`, `feelings`, `safety`
- `social story`, `beginner`, `core words`

→ **No new taxonomy needed.** Curate existing tags onto existing boards.

### 4. The grid + filter UI exists ✅
- [BoardsScreen.tsx](itty-bitty-frontend/src/pages/boards/BoardsScreen.tsx) supports `gridType="public"` — that's what `/public-boards` already uses
- [PresetBoardGroupsScreen.tsx](itty-bitty-frontend/src/pages/board_groups/PresetBoardGroupsScreen.tsx) powers `/board-categories`, `/board-sets`, `/categories` with featured/all/user segments + search
- [BoardTagFilterBar](itty-bitty-frontend/src/components/boards/) — tag filter UI
- [BoardGroupGrid](itty-bitty-frontend/src/components/board_groups/), `PresetBoardGrid`, `BoardGrid` — three grid components, ready to reuse

→ **No new grid components needed.** Either embed one, or route to one.

### 5. "Featured board groups" is a curation primitive ✅
[src/data/board_groups.ts:22](itty-bitty-frontend/src/data/board_groups.ts:22) — every `BoardGroup` has a `featured` boolean. `getPresetBoardGroups()` returns `featured_board_groups` as a separate bucket. Brittany (or any admin) can flip one switch to make a group front-page-featured.

→ **Curation tool already in place.** Create one group called "Classroom Essentials" with `featured: true`, drop existing boards into it.

### 6. The Free Generator hero pattern is reusable ✅
[FreeAACBoardGeneratorPage.tsx](itty-bitty-frontend/src/pages/public/FreeAACBoardGeneratorPage.tsx) already has the exact marketing-page chrome we need: TopNav, hero, CTA buttons, PostHog wiring (`free board generated`, `topic-selection-clicked`, etc.), back-to-home button, mobile-responsive layout, brand-consistent visual style.

→ **Copy the pattern, change the copy.** No new design system work.

### 7. What's actually missing
- **`hide_colors` and `qr_code` URL params** on `downloadPdf()` — backend supports them ([backend README §`GET /api/internal/boards/:id/export.pdf`](itty_bitty_boards/README.md)), frontend doesn't pass them. ~20 lines of code.
- **A "Classroom Essentials" featured board group** doesn't exist yet.
- **A teacher-themed landing page** doesn't exist yet.
- **`?source=teachers` attribution tagging** doesn't exist.

---

## Revised chunks (in priority order)

### Chunk A — Content audit + curation *(Brittany, 30–60 min)*
Run in `bin/console`:

```ruby
# What admin-owned public boards already exist that match teacher tags?
Board.public_boards.where("tags && ARRAY[?]::varchar[]",
  %w[school "visual schedule" "daily routine" "choice board" "first-then" feelings safety])
  .pluck(:name, :slug, :tags)
```

Pick the best ~8–12. Identify which (if any) of the six target categories aren't covered:
- Morning Routine
- Visual Schedule
- Emotions
- Center Choices / Activity Choice
- Lunch & Snack
- Transitions

For any genuinely missing category, seed via the existing admin UI (`/admin/predefined-boards`) — no DB migration, no seed file edit.

Then in the admin UI:
1. Create a Board Group named **"Classroom Essentials"**
2. Add the curated boards
3. Set `featured: true`

That's it. The existing `PresetBoardGroupsScreen` now displays it in the "Featured" tab of `/board-categories`.

### Chunk B — PDF options in the frontend *(30 min)*
[src/data/boards.ts:317](itty-bitty-frontend/src/data/boards.ts:317) — extend `downloadBoardPdf` to accept `hideColors` and `qrCode` params, append them to the query string. The backend already handles them.

```typescript
export const downloadBoardPdf = async (
  id: string,
  screenSize: string,
  opts?: { hideHeader?: boolean; hideColors?: boolean; qrCode?: boolean },
) => { /* ... */ }
```

Then update the existing PDF-download UI on board view pages to expose "Black & White" and "Include QR code" toggles. Optional polish — not blocking for the landing page.

### Chunk C — The landing page itself *(2–3 hours)*
New: `src/pages/public/FreePrintableAACBoardsPage.tsx`.

Structure:
1. **Hero** — copy the chrome from `FreeAACBoardGeneratorPage` (TopNav, kinda-light-overlay background, IonPage shell). Swap in the teacher copy from [free-printable-aac-boards.md](free-printable-aac-boards.md).
2. **CTAs** point to:
   - Primary: `/board-categories?source=teachers` (lands on Classroom Essentials featured group)
   - Secondary: `/free-aac-board-generator?source=teachers` (custom board generator with attribution)
3. **Six-card example grid** — pull the Classroom Essentials board group via existing `getBoardGroup()` or `getPresetBoardGroups()`. Each card links to `/boards/:slug` for view, with a small "Download PDF" link that calls `downloadPdf()` with the QR + B&W options exposed.
4. **Final CTA** + footer.

No new components. Reuse `TopNav`, `MarketingHeader`, `MarketingSideMenu`, `BoardGrid` (or a cut-down variant).

### Chunk D — Route + redirect + analytics *(30 min)*
- Add `/free-printable-aac-boards` to `App.tsx`
- `netlify.toml` redirect `/for-teachers` → `/free-printable-aac-boards`
- PostHog event `teachers_landing_cta_clicked` — mirror the pattern from `FreeAACBoardGeneratorPage.tsx:46–48`
- Use `posthog.capture()` with `target_path` + `label` properties
- Pick up `?source=teachers` query param wherever signup-attribution lives (it already does for the generator)

### Chunk E — OG image + SEO *(1–2 hours, can punt to design)*
- 1200×630 standard OG
- 1000×1500 Pinterest variant
- Title + meta description (drafted)
- Add to `sitemap.xml`
- Internal links from `/`, `/features`

### Chunk F — Verification + PR *(1 hour)*
- `npm run dev`, click every CTA
- Logged-out → click a Classroom Essentials board → download PDF → scan QR → verify it opens the public board view
- Mobile spot-checks (iPad, iPhone, Android)
- CHANGELOG entry
- PR open with screenshots + test plan

---

## Revised time estimate

| Chunk | Original | Revised |
|---|---|---|
| Content (seeding) | 2–4 hrs | 30–60 min *(audit + curate, not build)* |
| Landing page | 2–3 hrs | 2–3 hrs *(same, but heavy reuse)* |
| PDF B&W / QR options | — | 30 min *(was implicit, now explicit)* |
| Routes + redirects + analytics | 30 min | 30 min |
| OG images + SEO | 1–2 hrs | 1–2 hrs |
| Verification + PR | 1 hr | 1 hr |
| **Total** | **1.5–2 days** | **~½ day to 1 day** |

**~60% reduction**, driven entirely by the realization that the public-boards/featured-groups/PDF-export infrastructure already works.

---

## Open questions remaining

These are smaller now:

1. **Does Free plan have a separate PDF download cap?** Was a big risk before; now I'd bet it's ungated (the `pdf` action is unauthenticated, so there's no per-user counter wired to it). Worth a 5-min grep of `subscription.rb` and `application_controller.rb` to confirm.
2. **What's actually in `Board.public_boards` today?** Chunk A answers this in 5 minutes via Rails console. The whole plan flexes based on the answer — if there are already 30+ relevant boards, this is mostly a curation + landing-page exercise. If there are only 5 and most are demo-quality, we need to seed more before launching.
3. **Should "Classroom Essentials" be a Board Group (a curated set of boards) or just a tag-based filter view?** Board Group gives a nicer landing experience (featured, ordered, on its own page). Tag filter is more flexible. Recommendation: Board Group, since the featured-groups UX already exists and is more visually polished.

---

## Recommended next move

**Do Chunk A first, alone, before any code.** 30 minutes in Rails console + admin UI tells us whether we're building a thin landing page on top of strong existing content (likely) or whether we need a substantial seeding pass (possible). The answer dictates whether this is a half-day project or a multi-day one.

If Chunk A reveals strong content → ship Chunks B–F as a single PR over a focused day.

If Chunk A reveals weak content → pause, decide whether to invest in seeding (Brittany's time) or punt the landing page until the public-boards library is fuller.

---

## Addendum — seed-state audit from outside the database

*Added after a deeper read of `db/seeds.rb`, `db/seed_data/`, `app/models/seed_helper.rb`, and `lib/tasks/words.rake`. The production database state can't be known from outside, but the seed files and rake tasks tell us what content the codebase ships with.*

### What the seed files contain

| File | Topics defined | Teacher-relevant? |
|---|---|---|
| `seed_data/default/default1.json` | Basic Needs, Social Interaction, Feelings/Emotions, Questions, Common Verbs, Descriptive Words | ⭐ Feelings/Emotions, Social Interaction, Questions, Common Verbs — all core classroom vocabulary |
| `seed_data/default/default2.json`, `default3.json` | *(not inspected — likely more vocabulary buckets)* | Probably more of the same |
| `seed_data/routines/routines1.json` | Getting Ready for Bed, **Morning Routine**, **Mealtime**, + more | ⭐ Morning Routine and Mealtime map directly to our targets |
| `seed_data/scenarios/scenarios1.json` | At the Bank, Grocery Store, Restaurant, Post Office, **Doctor's Office** | Mostly community settings; Doctor's Office is teacher-adjacent |
| `seed_data/words/core.rb` | Core words | Universal |

### Coverage map to the six target landing categories

| Landing card | Covered in seed? | How |
|---|---|---|
| Morning Routine | ✅ Yes | `routines1.json` → "Morning Routine" |
| Visual Schedule | ❌ No | Would need new seed (can derive from routine data) |
| Emotions | ✅ Yes | `default1.json` → "Feelings/Emotions" |
| Center Choices | ❌ No | Would need new seed |
| Lunch & Snack | ⚠️ Close | `routines1.json` → "Mealtime" (rename or split) |
| Transitions | ❌ No | Would need new seed |

→ **3 of 6 cards have existing seed content. 3 need to be created.**

### The two flag-setting traps

Big finding: **none of the existing seed paths produce boards that show up in `Board.public_boards`.**

`Board.public_boards` requires `predefined: true` AND `published: true`. But:

- **`SeedHelper.seed_boards_from_file`** (the only active seeder in `seeds.rb`) sets neither flag. Boards created via `SeedHelper.run_all` are admin-owned but not predefined and not published. They won't appear publicly.
- **`lib/tasks/words.rake`** sets `predefined: true` but **not** `published: true`. Boards from that task are also invisible to `public_boards`.

This means **whatever public boards exist today were almost certainly created/published manually via the admin UI** (`/admin/predefined-boards` and similar). The seed scripts on their own don't produce public-visible content.

### What this tells us about the production DB

I can't see live state, but I can infer:

- If Brittany has been actively curating in `/admin/predefined-boards`, there are probably *some* public boards — quality and topic coverage unknown.
- If she hasn't, `Board.public_boards.count` is likely small or zero, and `/public-boards` is mostly empty.
- The "Classroom Essentials" Board Group definitely doesn't exist yet — there's no code path that creates it.

### Recommendation: a one-line read-only audit

Brittany can run this in her terminal (not Rails console — just `bin/rails runner`):

```bash
bin/rails runner '
  puts "Total public boards: #{Board.public_boards.count}"
  puts "Public boards with school/visual/routine/choice tags:"
  Board.public_boards.where("tags && ARRAY[?]::varchar[]",
    %w[school home "visual schedule" "daily routine" "choice board" "first-then" feelings safety])
    .pluck(:name, :tags).each { |n, t| puts "  - #{n} #{t.inspect}" }
  puts ""
  puts "Featured board groups: #{BoardGroup.featured.pluck(:name).inspect}"
  puts "Classroom group exists: #{BoardGroup.exists?(name: "Classroom Essentials")}"
'
```

Output tells us in 30 seconds whether to:
- **Build immediately** (strong existing content, no seeding needed)
- **Seed first** (need to create 3–6 missing boards + the Classroom Essentials group)
- **Punt** (public board library is too thin to support a teacher campaign right now)

### If we need to seed

I can write `lib/tasks/classroom_boards.rake` that creates the missing 3 boards (Visual Schedule, Center Choices, Transitions) and a "Classroom Essentials" featured Board Group, following the `words.rake` pattern but *also* setting `published: true` and tags. This is the lowest-risk path because:

- It's a one-shot rake task, not a destructive migration
- It uses `find_or_create_by!` so re-runs are safe
- It mirrors a pattern that already exists in the codebase
- It can be reviewed before running

### Updated time estimate after this audit

| Scenario | Engineering time |
|---|---|
| Strong existing public boards (≥8 teacher-relevant, already published) | ~½ day |
| Partial coverage (3–6 boards exist, need to seed 3–6 more + create Classroom group) | ~1 day (½ day for seeding + ½ day for landing page) |
| Weak coverage (need to seed 6+ boards from scratch with AI images) | 2 days |

The bash one-liner above tells us which row we're in.
