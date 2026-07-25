# Writing suggestions (contextual field help)

`POST /api/suggestions` returns three short starter sentences for a free-text
field. v1 covers About Me (`profiles.bio`) only, from two frontend surfaces.

## The load-bearing rule

**The client names a field; the server decides what becomes context.** The
request carries a `field_key`, an optional `subject_id`, and (only for the
onboarding variant) an `inline_context` whose keys are themselves allow-listed.
It never carries prompt text or arbitrary context values. Break this and the
endpoint becomes a general OpenAI proxy anyone can bill to SpeakAnyWay.

## The privacy invariant

No key in `Profile::SAFETY_SENSITIVE_KEYS` may appear in any registry allow-list
— allergies, medical conditions, medications, other conditions, emergency notes,
and emergency contacts never reach OpenAI. This is enforced by
`spec/services/suggestions/registry_spec.rb`, not by convention. If that spec
blocks a change you are making, the spec is right.

This is why emergency notes are NOT an AI surface: with no sensitive context
allowed, suggestions there can't be personalized, so v2 ships them as a curated
static list with no API call at all.

## Pieces

- `Suggestions::Registry` — per-field declaration. Adding a surface is one entry.
- `Suggestions::ContextBuilder` — resolves allow-listed keys only, drops blanks.
  AAC attributes live on `ChildAccount#details`, not on the `Profile`.
- `Suggestions::Generator` — OpenAI in JSON mode. **Always returns an array of
  strings, never nil, never raises.** Fixtures whenever
  `Suggestions::Generator.use_fixtures?` (staging or test); specs exercising the
  live path stub that to false.
- `API::SuggestionsController` — auth, ownership via
  `profile.profileable.editable_by?`, toggle check, 1-hour `Rails.cache`.

## Deliberate choices

- **Free.** No `check_credits!`, no `FEATURE_COSTS` entry; a request spec asserts
  no `CreditTransaction` is created. Free-plan users get 25 credits/month and
  this is onboarding help, not a power feature.
- **Failure is invisible.** An upstream error renders 200 with `[]`. A parent
  mid-onboarding never sees a stack trace because OpenAI was down.
- **Toggle is opt-out.** `user.settings["ai_writing_suggestions"]`; absent means
  on, so no backfill was needed.
- **Own OpenAI client.** `request_timeout` is a *client* option in `ruby-openai`,
  not a `chat` parameter — passing it in `parameters:` sends an unknown field to
  the API. The generator builds its own client for the shorter (15s) interactive
  timeout rather than reusing `OpenAiClient`'s 60s one.
- Throttling rides the existing Rack::Attack `ai_generation/user` rule via
  `ai_generation_request?` — no new rule.
