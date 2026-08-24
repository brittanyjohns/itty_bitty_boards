# AI prompting — the shared kernel

How a prompt is built in this app, and why the pieces sit where they do.
Image prompting is a separate subsystem (`.claude-notes/image-generation.md`);
this covers TEXT generation.

## `Prompts::Aac` is the source of truth for AAC word selection

`app/services/prompts/aac.rb` holds the persona, the word-selection rules, the
part-of-speech clause, and the word-list schema builder. Everything that asks a
model to choose words for a board goes through it.

This text was written for the admin Board Builder and used to live inside
`Boards::AdminBuilder::Drafting`, which meant the only prompts carrying any of
it were the ones an admin triggers a few times a day. Every user-facing
suggestion — "suggest words for this board", "add more words", the scenario
builder, interest pages — was a single user message with no persona and no
rules, so the model was asked, in effect, for a topical vocabulary list. That
is the exact failure `SYSTEM_PROMPT` exists to name: *"A board that can only
name things has failed even if every word on it is correct."*

Two personas, and the difference is load-bearing:

- `SYSTEM_PROMPT` — for prompts that draft TILES (label + part of speech).
- `WORD_LIST_SYSTEM_PROMPT` — for prompts that return LABELS ONLY. Their
  callers derive the part of speech separately (`AacWordCategorizer`), so
  demanding one would ask for a field nothing reads.

`WORD_RULES` is opt-in per call, not baked into the persona. **A list is not
always a vocabulary list.** Social-story steps are an ordered sequence, where
"no near-duplicates" and "include a way to refuse" pull against the task — those
callers pass the persona alone via `aac_word_chat(system_prompt:)`. Ask whether
the rules fit before adding a caller.

## Who uses the kernel

Every text prompt that drafts tiles or picks words, including
`AiBoardFormatter` — the "Format with AI" button. That one was the last holdout:
a single user message with no persona, its own restatement of the
part-of-speech list in prose, and `json_object` instead of a schema. It now
sends `SYSTEM_PROMPT` in the system slot, interpolates
`Prompts::Aac.part_of_speech_rules(arrangement_rule: Boards::TileArrangement::PROMPT_RULE)`,
and pins its response with a `json_schema` plus the usual retry-without-schema
rung. Asking for the same band order Ruby then enforces is the point: the prompt
and `TileArrangement.arrange` cannot drift.

It also no longer asks for a tile SIZE. It used to permit "up to 2" tiles at
`[2, 1]`, which the model took every run — see the invariant in `CLAUDE.md`.
A size the prompt cannot express is a size the model cannot get wrong; that is
the general shape of the fix when a model keeps taking an optional permission.

## What is shared and what is not

`AdminBuilder::Drafting` keeps its own `MODEL`, `TEMPERATURE`,
`REASONING_EFFORT` and `REQUEST_TIMEOUT`. Those are measured decisions about a
bigger model doing a harder job and are documented in
`.claude-notes/board-builder.md` — only the words are shared.
`Drafting::SYSTEM_PROMPT` and `::WORD_RULES` remain as delegating aliases so
nothing downstream re-points, and a spec asserts they still match.

## Rails for a new prompt

- **System message, always.** Persona and non-negotiables in the system slot;
  the request and its data in the user slot. Stuffing everything into one user
  message is what the legacy layer did.
- **Schema over prose.** Pin the response shape with a Structured Outputs
  `json_schema`, not a sentence describing JSON. `Prompts::Aac.word_list_schema`
  builds one for a plain list. `json_object` only says "some JSON" — a
  well-formed object with the wrong keys is legal, which is why four separate
  hand-rolled JSON-repair helpers grew up around these calls.
- **The response key stays per-caller, and that is deliberate.** `words`,
  `additional_words`, `next_words`, `words_phrases` are each read by their own
  consumer. Pinning the key in the schema is what stops them drifting;
  collapsing them to one name would move the risk into eight consumer sites for
  no gain.
- **Set a temperature.** Word selection is a counting exercise as much as a
  creative one — "exactly N, no duplicates, include a way to refuse" — and the
  provider default wanders on all three. `OPENAI_WORD_TEMPERATURE` (0.4)
  matches `Drafting`'s, for the same reason.
- **Retry down a ladder.** `OpenAiClient#create_chat` swallows an API error into
  `{ role: nil, content: nil }`, so a rejected parameter is indistinguishable
  from "the model had nothing to say". Every schema-using caller retries once
  without the schema. Do not remove that without fixing `create_chat` first.
- **Never restate the part-of-speech list in prose.** Interpolate
  `ColorHelper::PARTS_OF_SPEECH`; see the invariant in `CLAUDE.md`.

## Sentinels

`get_next_words` used to answer with the literal string `NO NEXT WORDS` when a
word had no follow-ons, which a schema cannot express. It returns an empty array
now — and `ImageHelper#get_next_words` converts empty to **nil**, because
`Image#set_next_words!` tests the result for truthiness to decide whether to set
`no_next`, and `[]` is truthy in Ruby. Returning the empty array straight
through would store an empty list, leave `no_next` false, and re-ask OpenAI for
that label on every subsequent call. If you add a sentinel, check what
truthiness means to the caller.

## Known gaps (not yet addressed)

- No eval harness, judge, or regression corpus. Every model default is
  ENV-tunable without a deploy, so a model swap ships with no evidence.
- `create_chat` still swallows errors, discards `usage` (no token/cost
  accounting), and has no retry of its own.
- The `AppEnv.staging?` guard is uneven: honoured by coaching, suggestions and
  the vision services, absent from the scenario builder and AdminBuilder.
- `Suggestions::Generator#system_prompt` carries hard safety rules (never invent
  a fact about a child, never diagnose) that no spec asserts.
