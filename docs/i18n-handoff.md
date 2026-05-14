# Internationalization / Multilingual — Handoff

Status as of 2026-05-14. This document is the single source of truth for
finishing multilingual support across the SpeakAnyWay backend
(`itty_bitty_boards`) and frontend (`itty-bitty-frontend`).

It describes **what already shipped**, **what is left**, and the **exact
next steps** — in priority order — to reach "fully working."

---

## TL;DR — what "done" means

A user (or communicator account) whose language is set to a supported
non-English language gets:

1. **UI chrome** (buttons, headings, menus, forms, errors) in their language — *partially done* (Settings page only).
2. **Board content** — image/tile labels in their language — *backend done, flows automatically*.
3. **Audio** — TTS playback in their language — *partially done, needs verification*.
4. **AI-generated content** — word suggestions, board/scenario generation in their language — *NOT done*.
5. **Emails** — transactional emails in their language — *infra done, 1 of ~20 templates migrated*.

The 12 supported languages (canonical list = `Image.languages`):
`en, es, fr, de, it, ja, ko, nl, pl, pt, ru, zh`.

---

## What already shipped (merged to production 2026-05-14)

### Backend — PR #99 (closed #96, #93, #94, #95)

- **`LocaleResolution` concern** (`app/models/concerns/locale_resolution.rb`)
  — `#i18n_locale` returns an ISO 639-1 symbol (`:es`) from a stored BCP-47
  value (`es-US`). Included in `User` and `ChildAccount`.
- **`config/application.rb`** — `available_locales` (the 12), `default_locale = :en`, `fallbacks = [:en]`.
- **Migration `NormalizeUserVoiceLanguage`** — rewrote legacy bad data
  (`"English"` → `"en-US"`) in `users.settings.voice.language`.
- **`Image#localized_label(lang)` / `#localized_display_label(lang)`** — read
  from `images.language_settings[lang]`, fall back to English `label`, and
  lazily enqueue `TranslateImageJob` when a supported translation is missing.
- **`BoardImage#localized_label` / `#localized_display_label`** — delegate to
  the underlying `Image`.
- **`TranslateImageJob`** — idempotent single-image OpenAI translation.
- **`TranslateBoardImagesJob`** — fans out per-image jobs for a whole board.
- **`Board#schedule_translations_for(lang)`** — rate-limited (1h `Rails.cache`)
  enqueue; called from `api_view_for_native_grid` and
  `api_view_with_predictive_images`.
- **Serializers** now honor the viewer's `i18n_locale`: `BoardImage#api_view`,
  `BoardImage#index_view`, `Board#api_view_for_native_grid`,
  `Board#api_view_with_predictive_images`, `Image#api_view`.
- **`lib/tasks/translate.rake`** — `translate:board BOARD_ID= LANG=` and
  `translate:public_images LANG=`.
- **Mailer i18n infra** — `BaseMailer#with_user_locale`,
  `config/locales/mailer.{en,es}.yml`. **`UserMailer#welcome_email` is the
  only migrated mailer** (subject + body).

### Frontend — PRs #92 and #94 (closed #91, #93, #90)

- **`SUPPORTED_LANGUAGES`** in `src/data/users.ts` — 12 langs, BCP-47 values.
- **`UserSettingsForm` / `AdminUserSettingsForm`** — language picker saves ISO
  codes (was saving `"English"`); voice/language/speed select fields now
  actually render (they were dead config before).
- **react-i18next stack** installed: `i18next`, `react-i18next`,
  `i18next-browser-languagedetector`.
- **`src/i18n/index.ts`** — 12 locales, English fallback, `toI18nLocale`
  helper (BCP-47 → ISO). Bootstrapped in `src/main.tsx`.
- **`src/locales/{en,es}.json`** — translation bundles, **Settings page keys
  only**.
- **`UserSettingsForm` fully migrated to `t()`** — the proof slice.
- Language switch persists: `UserSettingsForm` save calls
  `i18n.changeLanguage`; `UserContext.fetchUser` syncs i18n to the saved
  setting on app load.
- **`NativeTile.tsx` already renders `display_label || label`** — so once the
  backend serves localized labels, board tiles show them with **no frontend
  change needed**.

---

## What is left — exact next steps, in priority order

### Phase 1 — Backend content completeness (highest leverage)

The backend is the source of truth for everything except UI chrome. Finish it
first so the frontend has localized data to render.

**1.1 — AI generation must respect language** *(the known gap; no issue yet — file one)*
- `OpenAiClient#get_word_suggestions(name, count, exclude, board_type)`
  (`app/models/open_ai_client.rb:477`) takes **no language param** — always
  English. Add a `language` param and append `"Respond in #{LONG_LANGUAGE_NAMES[lang]}."`
  to the prompt, mirroring `get_additional_words` (`open_ai_client.rb:459-462`).
- `Board#get_word_suggestions` (`app/models/board.rb:2161`) must pass a
  language through. **Decide the source of truth**: `board.language` or the
  requesting `current_user.i18n_locale`. Recommendation: pass
  `current_user.i18n_locale` from the controller, fall back to
  `board.language`, fall back to `"en"`.
- Same treatment for the scenario builder path (`Board#get_words_for_scenario`,
  `app/models/board.rb:2147`) and `get_words` /`get_additional_words` — confirm
  they receive the *user's* language, not just `board.language`.
- Controllers to thread language through: `app/controllers/api/boards_controller.rb`
  (word suggestion / generation actions), `app/controllers/api/scenarios_controller.rb`.
- Tests: each `OpenAiClient` method with a non-`en` language asserts the
  prompt contains the "Respond in <language>" instruction.

**1.2 — New boards/images should default to the creator's language**
- `app/controllers/api/boards_controller.rb:320,384` only set
  `@board.language` when the param is present. On create, default it to
  `current_user.i18n_locale.to_s` when the param is blank.
- Verify `BoardImage` / `Image` `language` columns inherit sensibly (see
  `BoardImage#set_labels`).

**1.3 — Fix the `BoardImage#set_labels` symbol/string bug**
- `app/models/board_image.rb:106-112`: `image.language_settings[lang.to_sym]`
  — but `language_settings` is a jsonb column with **string** keys (see how
  `Image#translate_to` writes them). This lookup silently returns `{}`.
  Change to `lang.to_s`. Add a regression test.

**1.4 — Backfill translations for the public image library**
- Existing admin/public images have empty `language_settings`. The
  `translate:public_images LANG=<iso>` rake task exists but has not been run.
- Run it per target language **after** Phase 4's language decision, or at
  least for `es` now. Watch OpenAI cost — it's one API call per untranslated
  image.

**1.5 — Verify per-language TTS audio generation**
- Audio files are stored with a `_<lang>` filename suffix
  (`app/models/audio_helper.rb`). Confirm that when a board/image has a
  non-`en` language, `CreateAllAudioJob` / `VoiceService.synthesize_speech`
  actually generates and resolves the language-specific audio, and that
  `default_audio_url` picks the right file for the viewer's language.
- Manual test: a Spanish board image → tap → hear Spanish audio.

### Phase 2 — Frontend UI chrome migration (the bulk of the work)

Only `UserSettingsForm` is migrated. Everything else is hardcoded English.
Tracked by existing issues — work them in this order:

| Issue | Area | Files |
|-------|------|-------|
| itty-bitty-frontend#95 | Auth — sign-in/up, password reset, invites | `src/pages/SignInPage.tsx`, `SignUpPage.tsx`, `src/pages/auth/*` |
| itty-bitty-frontend#96 | Dashboard + Boards list | `src/pages/Dashboard.tsx`, `src/pages/boards/BoardsScreen.tsx`, `src/components/boards/*` |
| itty-bitty-frontend#97 | Board view + image grid chrome | `src/pages/boards/ViewBoard.tsx`, `src/components/board_images/*` (tile *labels* already localized via API — this is buttons/modals/headers only) |
| itty-bitty-frontend#98 | Onboarding + Pricing + Marketing pages | `src/pages/OnBoardingPage.tsx`, `PricingPage.tsx`, `Features.tsx`, etc. |
| itty-bitty-frontend#99 | Admin + Marketing components | `src/pages/admin/*`, `src/components/marketing/*` |

**The mechanical pattern** (proven in `UserSettingsForm.tsx`):
1. `import { useTranslation } from "react-i18next"`, then `const { t } = useTranslation();`
2. Replace inline copy with `t("namespace.key")`.
3. Add the keys to `src/locales/en.json` **and** `src/locales/es.json`.
4. The shape-parity test in `src/i18n/i18n.test.ts` fails if `es.json` is
   missing a key — keep it green.

Recommended: add a dedicated JSON namespace per area (`auth`, `dashboard`,
`boards`, `board_view`, `onboarding`, `admin`) to keep bundles navigable.

**Also add a visible language switcher** in app chrome (header or side menu)
so users don't have to dig into Settings. It should call
`i18n.changeLanguage()` and persist to the backend user setting (same as
`UserSettingsForm` does on save).

### Phase 3 — Remaining mailer templates (itty_bitty_boards#102)

Only `welcome_email` is migrated. ~19 templates remain across `UserMailer`,
`SetupMailer`, `PartnerMailer`, `BaseMailer`, `CommunicationAccountMailer`.

Pattern (proven in `UserMailer#welcome_email`):
1. Wrap the `mail(...)` call in `with_user_locale(recipient)`.
2. Subject via `I18n.t("...")`; body strings via `t("...")` in the `.erb`.
3. Add keys to `config/locales/mailer.en.yml` and `mailer.es.yml`.
4. Spec: renders English for `en` user, Spanish for `es` user.

Admin-facing mailers (`AdminMailer`) can stay English — note that decision in
the issue.

### Phase 4 — Language expansion: en + es → all 12

Both `es` (done) and the other 10 are needed for "complete."

- **Frontend** (itty-bitty-frontend#100): create `src/locales/<lang>.json`
  for `fr, de, it, ja, ko, nl, pl, pt, ru, zh`, mirroring `en.json`'s shape;
  import each into `src/i18n/index.ts` `resources`; extend the shape-parity
  test to cover every bundle.
- **Backend**: create `config/locales/mailer.<lang>.yml` for the same 10.
- **Do this AFTER Phases 2 & 3** so the key set has stabilized — otherwise
  you re-translate churned keys repeatedly.
- Translation approach: AI-assisted batch translation, then native-speaker
  review. The `i18next` English fallback means partial bundles are safe to
  ship incrementally.

### Phase 5 — End-to-end verification & monitoring

Before calling it done, run a full E2E pass with a real non-English user:

1. Create a user with `settings.voice.language = "es-US"`.
2. **UI chrome** — every migrated page renders in Spanish; language switcher works and persists.
3. **Board content** — open a board: tile labels are Spanish (lazily
   translated on first load, instant on subsequent loads).
4. **Audio** — tap a tile: Spanish TTS plays.
5. **AI** — request word suggestions / generate a board: results are Spanish.
6. **Email** — trigger welcome + any migrated transactional email: arrives in Spanish.
7. Repeat spot-checks for a `ChildAccount` (communicator) with its own language.

**Monitoring:** when non-English users arrive, `TranslateImageJob` /
`TranslateBoardImagesJob` fire OpenAI calls on first board load (rate-limited
1h per board+lang). Watch the OpenAI bill and the Sidekiq `default` queue
depth on the first few non-English signups.

---

## Known constraints & notes

- **No multilingual users exist yet** — the machinery is dormant until the
  first non-English user. The Phase-1 backend code only does work for
  non-`en` viewers; English users see byte-identical behavior.
- **Language code formats**: user/communicator settings store **BCP-47**
  (`es-US`) for TTS providers; content lookups use the **ISO 639-1** prefix
  via `#i18n_locale` / `toI18nLocale`. Don't mix them.
- **RTL**: none of the 12 supported languages are right-to-left, so no layout
  work is needed now. If Arabic/Hebrew is ever added, that becomes a real
  frontend effort.
- **`board.language` vs user language**: currently most AI paths key off
  `board.language` (default `"en"`). Phase 1.1/1.2 resolves this — decide
  and document the precedence once.

## Open issues

- itty_bitty_boards#102 — remaining mailer templates (Phase 3)
- itty-bitty-frontend#95–#99 — per-area UI migration (Phase 2)
- itty-bitty-frontend#100 — locale bundles for the other 10 languages (Phase 4)
- **Not yet filed**: "AI word suggestions + board/scenario generation respect
  language" (Phase 1.1) — file under the `multilingual support` label.

## Reference — the proven patterns

- Backend mailer i18n: `app/mailers/user_mailer.rb` `welcome_email`,
  `app/views/user_mailer/welcome_email.html.erb`, `config/locales/mailer.en.yml`.
- Backend content i18n: `app/models/image.rb` `localized_label`,
  `app/sidekiq/translate_image_job.rb`.
- Frontend UI i18n: `src/components/users/UserSettingsForm.tsx`,
  `src/i18n/index.ts`, `src/locales/en.json`.
