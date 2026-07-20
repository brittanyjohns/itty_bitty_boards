# Video tile trim range — design

**Date:** 2026-07-20
**Repos touched:** `itty_bitty_boards` (backend), `itty-bitty-frontend` (frontend)
**Status:** approved, ready for implementation planning

## Problem

Per-tile video actions currently play a whole YouTube video. For AAC use — an ASL
sign demo, a single step in a routine — the useful content is often a few seconds
buried in a longer video. A communicator shouldn't have to sit through the rest,
and a caregiver shouldn't have to find and clip the video elsewhere first.

YouTube's iframe embed supports `start` and `end` URL params in whole seconds, so
this is achievable without hosting or re-encoding anything.

## Scope

**In:** optional start/end trimming for the YouTube video source.

**Out (deliberate):** trimming for uploaded clips. Uploads are already capped at
30 seconds server-side by `ProcessTileVideoJob`, so trimming buys little today.
The data shape below is source-agnostic specifically so uploads can adopt it later
without a migration.

Ships behind the existing admin gate on the Video tab
(`BoardImageModal.tsx`), consistent with the current quiet prod rollout.

## Constraints from the existing feature

These are established facts about the current implementation that shape the design:

- Video is a JSON blob in the existing `board_images.data` jsonb column
  (`{ source, youtube_id }`). There is no `Video` model or table.
- Only the 11-character YouTube ID is persisted. The raw pasted URL is discarded
  so user input never reaches an iframe `src`.
- `board_images_controller.rb:51` strips `video` from the generic tile-update
  params (`data = data.except(:video)`). This is load-bearing security: it is the
  only thing preventing a hostile `video` payload being written through a plain
  `PATCH`, bypassing `YoutubeUrlParser`.
- Web frames `youtube-nocookie.com/embed/<id>` directly. Native (Capacitor) frames
  our own `public/youtube-embed.html`, because `capacitor://localhost` sends no
  valid referrer and YouTube returns Error 153.
- `youtubeEmbedUrl` in `src/data/board_images.ts` is the single embed-URL helper,
  used by both the editor preview and the player.

## Design

### 1. Data shape

`board_images.data["video"]` gains two optional keys:

```ruby
{ "source" => "youtube",
  "youtube_id" => "dQw4w9WgXcQ",
  "start_seconds" => 45,
  "end_seconds" => 72 }
```

Keys are omitted entirely when unset — no null values stored. No migration and no
backfill: it is the same jsonb column, and existing tiles remain valid.

Names are source-agnostic rather than `youtube_start` so the uploaded-clip
follow-up reuses them as-is.

### 2. Backend

`POST /board_images/:id/attach_youtube_video` accepts `start_seconds` and
`end_seconds` alongside the existing URL param. `BoardImage#set_youtube_video!`
validates and persists them.

Validation rules:

- Both optional and independent — either, both, or neither may be supplied.
- Each must be a non-negative integer.
- If both are present, `end_seconds` must be strictly greater than `start_seconds`.

Failures return 422 with error key `invalid_video_range`, matching the existing
convention (`invalid_youtube_url`, `invalid_video_type`, `video_too_large`).

**No maximum range length.** Untrimmed YouTube playback is already unbounded, so
trimming can only ever shorten a clip. A cap would be a new restriction unrelated
to this feature. (Uploads keep their existing 30s cap, which is about storage and
transcode cost, not playback length.)

**The `data.except(:video)` guard is not modified.** Start and end flow only
through the dedicated endpoint. No new write path for video data is introduced.

**Editing a range without re-pasting the link:** because only the ID is stored,
the frontend reconstructs `https://www.youtube.com/watch?v=<youtube_id>` and
resubmits through the same endpoint. This keeps `YoutubeUrlParser` on the path for
every write and requires no backend change.

### 3. Frontend — embed and playback

Reaching the end timestamp auto-closes `TileVideoModal`, so the communicator taps
the tile, watches the clip, and lands back on the board with no extra tap.

Detecting "reached the end" requires the YouTube IFrame API to read playback
position. On native, the app cannot reach into a cross-origin frame. Rather than
maintain two different detection mechanisms:

**Route web through `youtube-embed.html` as well whenever a trim range is set.**
The proxy page becomes the single owner of all YouTube IFrame API interaction. It
reads `start` and `end` from its own query string, drives the player, and
`postMessage`s `{ type: "saw:video-ended" }` to the parent when playback passes
`end` (or the player reports state `ENDED`).

Untrimmed web videos continue to frame `youtube-nocookie.com` directly, so no
existing tile changes behavior. The routing condition becomes
`proxied || endSeconds != null`.

Changes:

- `BoardImageVideo` type gains `start_seconds?: number` and `end_seconds?: number`.
- `youtubeEmbedUrl(youtubeId, { autoplay, proxied, startSeconds, endSeconds })`
  appends the range params and applies the routing condition above.
- `public/youtube-embed.html` loads the IFrame API, honors `start`/`end`, and
  posts the end signal.
- `TileVideoModal` listens for that message and dismisses on receipt. The origin
  check must compare against the **embed page's** origin
  (`https://app.speakanyway.com`), not the app's own origin — on native the app
  runs at `capacitor://localhost` while the embed page is served from
  `app.speakanyway.com`, so checking `window.location.origin` would reject every
  legitimate message on native. Messages from any other origin are ignored. The
  existing offline guard and unknown-source fallback are unchanged.
- `public/_headers` — confirm the existing `frame-ancestors` rule for
  `/youtube-embed.html` still covers the web-origin case now that web may frame it
  too. Rule ordering here was previously a bugfix (commit `03d533c9`); do not
  reorder.

### 4. Frontend — editor

The Video tab (`BoardImageVideoTab.tsx`) gains two optional inputs, "Start" and
"End", next to the existing YouTube URL field.

- Accept either `1:23` or raw seconds, via a small shared parse helper.
- Client-side validation mirrors the server rules, so the common mistakes are
  caught before a round trip.
- The preview iframe reloads with the range applied, so the range can be checked
  before saving.
- Both fields are optional; leaving them blank preserves today's behavior exactly.
- New strings go in `src/locales/en.json` and `es.json`.

## Known limitations

Worth stating plainly, since they are inherent to the YouTube embed and not fixable
by us:

- **Whole seconds only.** The embed API accepts no fractional values.
- **The range is a hint, not a lock.** The scrub bar remains live, so a
  communicator can drag outside the trimmed range. `controls=0` does not reliably
  remove the progress bar across clients.
- **`end` pauses, it does not stop the session.** Our auto-close is what ends the
  interaction, which is why the postMessage path matters.

## Testing

**Backend** (`spec/requests/api/board_images_video_spec.rb`):

- Range params persist onto `data["video"]`; omitted params store no keys.
- 422 `invalid_video_range` for negative values, non-integers, and `end <= start`.
- Existing untrimmed attach behavior is unchanged.
- **New:** assert a `video` key in a plain `PATCH /board_images/:id` is dropped.
  This guard is load-bearing and currently has no spec covering it.

**Frontend:**

- `src/data/board_images.test.ts` — `youtubeEmbedUrl` emits `start`/`end`, and
  routes to the proxy page when `endSeconds` is set even on web.
- `youtubeEmbedPage.test.ts` — the real `public/youtube-embed.html` honors
  `start`/`end` and posts `saw:video-ended`.
- `BoardImageVideoTab.test.tsx` — mm:ss and raw-seconds parsing, validation
  messaging, blank fields round-trip cleanly.
- `TileVideoModal.test.tsx` — auto-close on a same-origin `saw:video-ended`
  message; message from a foreign origin is ignored.

## Shipping

Two PRs, backend first so the data shape lands before the UI writes to it.

Both primary checkouts are behind `origin/main` (backend by 5, frontend by 2), so
worktrees are cut from `origin/main`, not local `main`.

Docs to update in the same PRs: repo `CLAUDE.md` / `.claude-notes` where the video
data shape is described, and a `CHANGELOG.md` entry once the admin gate is lifted
(the change is not user-facing while gated).
