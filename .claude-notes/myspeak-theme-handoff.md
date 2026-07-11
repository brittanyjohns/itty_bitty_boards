# Handoff: MySpeak page themes (backend)

**Date:** 2026-07-08 · **Status:** backend done (issue #476) — awaiting merge + deploy
**Full plan:** `speakanyway/drafts/myspeak-theme-plan.md` (this doc is self-contained; the plan adds context)
**Counterpart:** `itty-bitty-frontend/.claude-notes/myspeak-theme-handoff.md` (blocked on this PR)

## Feature

Communicator MySpeak pages (`/my/<slug>`) get owner-picked visual themes:
preset palettes + optional color overrides, stored on the profile. The backend
work is small: expose a new `theme` settings key on the public payload and
sanitize it on write. Frontend defines the presets and renders the theme.

## Decisions (already made — don't re-litigate)

- Theme = presets + color overrides; **no image upload** in v1.
- **Owner-only** editing via the existing profile update endpoint. No new
  endpoints, no new auth surface.
- **Free for all plans** — no gating.
- Scope is the **communicator safety profile** (`profile_kind: "safety"`,
  `profileable_type: "ChildAccount"`). The user-level Public page
  (`settings.public_page.theme`, `PUBLIC_PAGE_KEYS`) is untouched.

## Current state

- `app/models/profile.rb` — the MySpeak page entity. `settings` jsonb.
  - `SAFETY_PAGE_KEYS = %w[pronouns device_notes]` (~line 442) whitelists
    what `#public_settings(kind: :safety)` returns, which is what
    `#safety_view` (~line 313) serializes to the public page.
  - `SAFETY_SENSITIVE_KEYS` (~line 453) are the gated emergency fields —
    do NOT touch that wall.
  - `bg_color` (~line 203) is a legacy deterministic slug-hash color; the
    frontend page doesn't use it. Leave it (other callers may) but the theme
    supersedes it.
- `app/controllers/api/profiles_controller.rb`
  - `#update` (~line 152) is owner-gated for ChildAccount profiles
    (`editable_by?` check) and `profile_params` (~line 376) already permits
    `settings: {}` — **no strong-params change needed**.
  - `#public` (~line 30) serves `GET /api/profiles/public/:slug` →
    `safety_view` for safety profiles.
- Existing specs for profiles: `spec/` — find with
  `grep -rl "safety_view\|profiles" spec/ | head`.

## Work items

1. **Whitelist the key.** In `app/models/profile.rb`:

   ```ruby
   SAFETY_PAGE_KEYS = %w[
     pronouns
     device_notes
     theme
   ].freeze
   ```

2. **Sanitize theme on write.** Theme values are rendered into inline CSS on
   an unauthenticated public page, so validate server-side. Add to `Profile`:

   ```ruby
   THEME_HEX_KEYS = %w[accent bg_color border_color text_color].freeze
   THEME_SLUG_KEYS = %w[preset bg_style].freeze
   HEX_COLOR_FORMAT = /\A#[0-9a-fA-F]{6}\z/.freeze
   THEME_SLUG_FORMAT = /\A[a-z0-9_-]{1,40}\z/.freeze

   before_save :sanitize_theme_settings

   def sanitize_theme_settings
     raw = settings.is_a?(Hash) ? settings["theme"] : nil
     return if raw.nil?

     unless raw.is_a?(Hash)
       settings.delete("theme")
       return
     end

     clean = {}
     THEME_HEX_KEYS.each do |k|
       v = raw[k].to_s.strip
       clean[k] = v if v.match?(HEX_COLOR_FORMAT)
     end
     THEME_SLUG_KEYS.each do |k|
       v = raw[k].to_s.strip
       clean[k] = v if v.match?(THEME_SLUG_FORMAT)
     end
     clean.empty? ? settings.delete("theme") : settings["theme"] = clean
   end
   ```

   Unknown keys are dropped (whitelist, not blocklist). Backend never needs
   the preset palette list — the frontend resolves preset → colors.

3. **Specs** (model + request):
   - `PATCH /api/profiles/:id` with `settings: { theme: {...} }` persists and
     returns the theme on `api_view`.
   - `GET /api/profiles/public/:slug` includes `settings["theme"]` for a
     safety profile.
   - Invalid values (`"red"`, `"#fff"`, `"javascript:alert(1)"`, nested
     junk, non-hash theme) are dropped/normalized.
   - Sensitive keys (`allergies`, `ice_contact_1`, …) are still absent from
     the public payload (guard the existing wall).
   - Non-owner PATCH still 403s (existing behavior, cheap to assert).

## Testing

```
bundle exec rspec spec/models/profile_spec.rb spec/requests/<profiles request specs>
```

Prefer `FactoryBot.build` where possible. No S3/ActiveStorage involvement.

## Deploy notes

- No migration (jsonb key), no ENV vars, no new routes.
- Ships safely alone: nothing reads `theme` until the frontend PR lands.
- Frontend PR (counterpart doc) depends on this being merged + deployed.

## API contract the frontend relies on after merge

- `settings.theme` (object with keys `preset`, `bg_style`, `accent`,
  `bg_color`, `border_color`, `text_color` — all optional, hex as `#RRGGBB`)
  round-trips through `PATCH /api/profiles/:id` and appears in
  `GET /api/profiles/public/:slug` → `settings.theme`.

## Git rules (Brittany's)

Branch off origin/main in a worktree. Never push to main or merge PRs — open
the PR and stop.
