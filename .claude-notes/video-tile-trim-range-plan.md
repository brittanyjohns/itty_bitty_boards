# Video Tile Trim Range Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a YouTube video tile play only a chosen slice of a video, via optional start/end second fields, auto-closing the playback modal when the slice ends.

**Architecture:** Two optional integer keys (`start_seconds`, `end_seconds`) are added to the existing `board_images.data["video"]` jsonb blob — no migration. The backend parses and validates them in the model and writes them only through the existing dedicated `attach_youtube_video` endpoint. On the frontend, any video with an `end_seconds` routes through our own `public/youtube-embed.html`, which drives the YouTube IFrame API and `postMessage`s an end-of-clip signal that closes `TileVideoModal` — one detection path instead of a separate one per platform.

**Tech Stack:** Rails 8 + RSpec (backend); React + Ionic + TypeScript + Vitest (frontend); YouTube IFrame Player API.

**Spec:** `.claude-notes/video-tile-trim-range.md` (same repo, read it first).

## Global Constraints

- Whole seconds only — the YouTube embed API accepts no fractional values.
- Both fields are independently optional. Blank fields must round-trip to today's exact behavior.
- Video config is written **only** through `attach_youtube_video` / `upload_video` / `clear_video`. The `data = data.except(:video)` strip in `board_images_controller.rb` is load-bearing security and must not be modified or bypassed.
- Only the validated 11-character YouTube id is ever persisted. The raw pasted URL is discarded.
- Embeds stay on `youtube-nocookie.com`, including when driven by the IFrame API (pass `host`).
- Error key for a bad range is `invalid_video_range`, HTTP 422 (`:unprocessable_content`), matching `invalid_youtube_url` / `invalid_video_type` / `video_too_large`.
- No maximum range length.
- Backend: Ruby snake_case, fat models / thin controllers. Frontend: arrow functions only, TypeScript strict, no `any`.
- Ships behind the existing `currentUser?.admin` gate on the Video tab — not user-facing yet, so no `CHANGELOG.md` entry.

## Repos and branches

**Backend** — worktree already exists:
`itty_bitty_boards/.claude/worktrees/video-trim-range`, branch `claude/video-trim-range` (cut from `origin/main`).

**Frontend** — Task 4 Step 1 creates it. Do not edit the primary checkout.

---

## File Structure

**Backend (`itty_bitty_boards`)**

| File | Responsibility |
|---|---|
| `app/models/board_image.rb` | Modify — `parse_video_range` class method (all validation lives here), `set_youtube_video!` accepts a range |
| `app/controllers/api/board_images_controller.rb` | Modify — `attach_youtube_video` reads the two params, renders 422 on a bad range |
| `spec/models/board_image_video_range_spec.rb` | Create — unit coverage for `parse_video_range` |
| `spec/requests/api/board_images_video_spec.rb` | Modify — endpoint behavior + the missing guard regression |

**Frontend (`itty-bitty-frontend`)**

| File | Responsibility |
|---|---|
| `src/data/board_images.ts` | Modify — type fields, `youtubeEmbedUrl` range + proxy routing, `attachYoutubeVideo` range args |
| `public/youtube-embed.html` | Modify — honor `start`/`end`, drive the IFrame API, post the end signal |
| `src/components/board_images/TileVideoModal.tsx` | Modify — pass the range through, listen for the end signal, close |
| `src/components/utils/parseTimecode.ts` | Create — `"1:23"` / `"83"` → seconds, one job only |
| `src/components/board_images/BoardImageVideoTab.tsx` | Modify — Start/End inputs wired to the parse helper |
| `src/locales/en.json`, `src/locales/es.json` | Modify — new strings |
| Matching `*.test.ts(x)` files | Modify/create per task |

---

## Task 1: Backend — range parsing and validation

All validation lives in the model (fat models, thin controllers). This task produces the parser and its unit tests; nothing calls it yet.

**Files:**
- Modify: `app/models/board_image.rb` (tile-video section, ~line 535)
- Test: `spec/models/board_image_video_range_spec.rb` (create)

**Interfaces:**
- Produces: `BoardImage.parse_video_range(start_raw, end_raw)` → `Hash` with whichever of the string keys `"start_seconds"` / `"end_seconds"` were supplied (`{}` when neither), or `nil` when the values don't describe a usable range. Task 2 and Task 3 depend on this exact contract — `{}` and `nil` are meaningfully different.

- [ ] **Step 1: Write the failing test**

Create `spec/models/board_image_video_range_spec.rb`:

```ruby
require "rails_helper"

# Trim points for a tile video. Whole seconds only — the YouTube embed API
# takes no fractional values. Returns {} for "no range supplied" and nil for
# "supplied but unusable"; the caller must be able to tell those apart.
RSpec.describe BoardImage, ".parse_video_range" do
  it "returns an empty hash when neither bound is supplied" do
    expect(described_class.parse_video_range(nil, nil)).to eq({})
    expect(described_class.parse_video_range("", "")).to eq({})
  end

  it "parses each bound independently" do
    expect(described_class.parse_video_range("45", nil)).to eq({ "start_seconds" => 45 })
    expect(described_class.parse_video_range(nil, "72")).to eq({ "end_seconds" => 72 })
    expect(described_class.parse_video_range("45", "72"))
      .to eq({ "start_seconds" => 45, "end_seconds" => 72 })
  end

  it "accepts integers as well as numeric strings" do
    expect(described_class.parse_video_range(45, 72))
      .to eq({ "start_seconds" => 45, "end_seconds" => 72 })
  end

  it "accepts zero as a start" do
    expect(described_class.parse_video_range("0", "10"))
      .to eq({ "start_seconds" => 0, "end_seconds" => 10 })
  end

  it "rejects negative values" do
    expect(described_class.parse_video_range("-1", nil)).to be_nil
    expect(described_class.parse_video_range(nil, "-5")).to be_nil
  end

  it "rejects fractional and non-numeric values" do
    expect(described_class.parse_video_range("3.5", nil)).to be_nil
    expect(described_class.parse_video_range("abc", nil)).to be_nil
    expect(described_class.parse_video_range(nil, "1:23")).to be_nil
  end

  it "rejects an end that is not strictly after the start" do
    expect(described_class.parse_video_range("72", "45")).to be_nil
    expect(described_class.parse_video_range("45", "45")).to be_nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/brittanyjohns/Projects/speakanyway/itty_bitty_boards/.claude/worktrees/video-trim-range
bundle exec rspec spec/models/board_image_video_range_spec.rb
```

Expected: FAIL — `undefined method 'parse_video_range' for BoardImage`.

- [ ] **Step 3: Write minimal implementation**

In `app/models/board_image.rb`, in the tile-video section directly above `def video_config`, add:

```ruby
  # Optional trim points for a tile video, in whole seconds (the YouTube embed
  # API takes no fractional values). Both bounds are independently optional.
  #
  # Returns a hash containing whichever bounds were supplied — {} when neither
  # was — or nil when the supplied values don't describe a usable range. The
  # caller must distinguish those: {} means "no trim", nil means "reject".
  def self.parse_video_range(start_raw, end_raw)
    parsed = {}
    { "start_seconds" => start_raw, "end_seconds" => end_raw }.each do |key, raw|
      next if raw.blank?
      seconds = Integer(raw.to_s, exception: false)
      return nil if seconds.nil? || seconds.negative?
      parsed[key] = seconds
    end
    if parsed.key?("start_seconds") && parsed.key?("end_seconds")
      return nil unless parsed["end_seconds"] > parsed["start_seconds"]
    end
    parsed
  end
```

Note: `0.blank?` is `false`, so an explicit zero start is preserved. `Integer("3.5", exception: false)` returns `nil`, which is what rejects fractional input.

- [ ] **Step 4: Run test to verify it passes**

```bash
bundle exec rspec spec/models/board_image_video_range_spec.rb
```

Expected: PASS, 7 examples, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/models/board_image.rb spec/models/board_image_video_range_spec.rb
git commit -m "feat(video-tiles): parse and validate optional trim range"
```

---

## Task 2: Backend — persist the range and wire the endpoint

**Files:**
- Modify: `app/models/board_image.rb` (`set_youtube_video!`, ~line 548)
- Modify: `app/controllers/api/board_images_controller.rb` (`attach_youtube_video`, ~line 281)
- Test: `spec/requests/api/board_images_video_spec.rb`

**Interfaces:**
- Consumes: `BoardImage.parse_video_range(start_raw, end_raw)` from Task 1.
- Produces: `set_youtube_video!(youtube_id, range = {})` where `range` is the hash from `parse_video_range`. `POST /api/board_images/:id/attach_youtube_video` accepts optional `start_seconds` and `end_seconds` params.

- [ ] **Step 1: Write the failing tests**

In `spec/requests/api/board_images_video_spec.rb`, inside the existing `describe "POST /api/board_images/:id/attach_youtube_video"` block, add:

```ruby
    it "persists an optional trim range alongside the video id" do
      post "/api/board_images/#{board_image.id}/attach_youtube_video",
           params: { url: valid_youtube_url, start_seconds: 45, end_seconds: 72 },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(board_image.reload.data["video"]).to eq({
        "source" => "youtube",
        "youtube_id" => "dQw4w9WgXcQ",
        "start_seconds" => 45,
        "end_seconds" => 72,
      })
    end

    it "stores no range keys when neither bound is supplied" do
      post "/api/board_images/#{board_image.id}/attach_youtube_video",
           params: { url: valid_youtube_url },
           headers: auth_headers(user)

      expect(board_image.reload.data["video"].keys)
        .to contain_exactly("source", "youtube_id")
    end

    it "accepts a start with no end" do
      post "/api/board_images/#{board_image.id}/attach_youtube_video",
           params: { url: valid_youtube_url, start_seconds: 45 },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      video = board_image.reload.data["video"]
      expect(video["start_seconds"]).to eq(45)
      expect(video).not_to have_key("end_seconds")
    end

    it "rejects an unusable range with 422 and writes nothing" do
      post "/api/board_images/#{board_image.id}/attach_youtube_video",
           params: { url: valid_youtube_url, start_seconds: 72, end_seconds: 45 },
           headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("invalid_video_range")
      expect(board_image.reload.data&.dig("video")).to be_nil
    end

    it "replaces a previous range when re-attached without one" do
      post "/api/board_images/#{board_image.id}/attach_youtube_video",
           params: { url: valid_youtube_url, start_seconds: 45, end_seconds: 72 },
           headers: auth_headers(user)
      post "/api/board_images/#{board_image.id}/attach_youtube_video",
           params: { url: valid_youtube_url },
           headers: auth_headers(user)

      expect(board_image.reload.data["video"].keys)
        .to contain_exactly("source", "youtube_id")
    end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bundle exec rspec spec/requests/api/board_images_video_spec.rb -e "trim range"
```

Expected: FAIL — the range keys are absent from the persisted hash.

- [ ] **Step 3: Write minimal implementation**

In `app/models/board_image.rb`, replace `set_youtube_video!`:

```ruby
  def set_youtube_video!(youtube_id, range = {})
    video_clip.purge_later if video_clip.attached?
    config = { "source" => "youtube", "youtube_id" => youtube_id }.merge(range)
    self.data = (data || {}).merge("video" => config)
    save!
  end
```

Update the shape comment at the top of the tile-video section to document the new keys:

```ruby
  #   { "source" => "youtube", "youtube_id" => "...",
  #     "start_seconds" => 45, "end_seconds" => 72 }   # trim points optional
```

In `app/controllers/api/board_images_controller.rb`, replace the body of `attach_youtube_video`:

```ruby
  def attach_youtube_video
    youtube_id = YoutubeUrlParser.video_id(params[:url])
    unless youtube_id
      render json: { error: "invalid_youtube_url" }, status: :unprocessable_content
      return
    end
    range = BoardImage.parse_video_range(params[:start_seconds], params[:end_seconds])
    unless range
      render json: { error: "invalid_video_range" }, status: :unprocessable_content
      return
    end
    @board_image.set_youtube_video!(youtube_id, range)
    @board_image.board.broadcast_board_update!
    render json: @board_image.api_view(current_user)
  end
```

- [ ] **Step 4: Run the full video spec to verify no regressions**

```bash
bundle exec rspec spec/requests/api/board_images_video_spec.rb spec/models/board_image_video_range_spec.rb
```

Expected: PASS, 0 failures. The pre-existing examples ("persists only the parsed video id", "preserves unrelated data keys") must still pass unchanged.

- [ ] **Step 5: Commit**

```bash
git add app/models/board_image.rb app/controllers/api/board_images_controller.rb spec/requests/api/board_images_video_spec.rb
git commit -m "feat(video-tiles): accept optional start/end seconds on attach"
```

---

## Task 3: Backend — regression spec for the generic-update guard

The `data.except(:video)` strip is the only thing stopping an arbitrary video payload reaching the DB through a plain `PATCH`, and it currently has no test. Now that a second write path exists conceptually, lock it down.

**Files:**
- Test: `spec/requests/api/board_images_video_spec.rb`

**Interfaces:**
- Consumes: nothing new. Asserts existing behavior at `board_images_controller.rb:51`.

- [ ] **Step 1: Write the test**

Add a new top-level `describe` block to `spec/requests/api/board_images_video_spec.rb`:

```ruby
  # The generic update path strips data["video"] so an unvalidated payload can
  # never reach an iframe src. This guard is load-bearing security — if a
  # refactor of the params method drops it, this spec is what catches it.
  describe "PATCH /api/board_images/:id (generic update)" do
    it "silently drops a video key rather than persisting it" do
      patch "/api/board_images/#{board_image.id}",
            params: { board_image: { data: { video: { source: "youtube", youtube_id: "dQw4w9WgXcQ" } } } },
            headers: auth_headers(user)

      expect(board_image.reload.data&.dig("video")).to be_nil
    end

    it "does not let a hostile url be injected through the data blob" do
      patch "/api/board_images/#{board_image.id}",
            params: { board_image: { data: { video: { source: "upload", url: "https://evil.example/x.mp4" } } } },
            headers: auth_headers(user)

      expect(board_image.reload.data&.dig("video")).to be_nil
    end

    it "still persists unrelated data keys through the same path" do
      patch "/api/board_images/#{board_image.id}",
            params: { board_image: { data: { hide_label: true } } },
            headers: auth_headers(user)

      expect(board_image.reload.data["hide_label"]).to eq(true)
    end
  end
```

- [ ] **Step 2: Run it**

```bash
bundle exec rspec spec/requests/api/board_images_video_spec.rb -e "generic update"
```

Expected: PASS immediately — this documents existing behavior rather than driving new code.

If the third example fails, the param shape is wrong for this controller. Check the `board_image_params` method in `app/controllers/api/board_images_controller.rb` and match its expected nesting before adjusting the other two.

- [ ] **Step 3: Run the whole backend video suite**

```bash
bundle exec rspec spec/requests/api/board_images_video_spec.rb spec/models/board_image_video_range_spec.rb spec/services/youtube_url_parser_spec.rb spec/sidekiq/process_tile_video_job_spec.rb
```

Expected: PASS, 0 failures.

- [ ] **Step 4: Commit and push**

```bash
git add spec/requests/api/board_images_video_spec.rb
git commit -m "test(video-tiles): cover the generic-update video strip"
git push -u origin claude/video-trim-range
```

Open the backend PR at this point — it is independently shippable. The frontend sends no range params yet, so nothing changes for users.

---

## Task 4: Frontend — types, embed URL, and API client

**Files:**
- Modify: `src/data/board_images.ts` (`BoardImageVideo` ~line 73, `youtubeEmbedUrl` ~line 105, `attachYoutubeVideo` ~line 312)
- Test: `src/data/board_images.test.ts`

**Interfaces:**
- Consumes: the backend contract from Task 2 — request params `start_seconds` / `end_seconds`, response keys of the same names inside `data.video`.
- Produces: `BoardImageVideo.start_seconds?: number` / `.end_seconds?: number`; `youtubeEmbedUrl(id, { autoplay?, proxied?, startSeconds?, endSeconds? })`; `attachYoutubeVideo(boardImageId, url, range?)`. Tasks 5–7 depend on these names.

- [ ] **Step 1: Create the frontend worktree**

```bash
cd /Users/brittanyjohns/Projects/speakanyway/itty-bitty-frontend
git fetch origin
git worktree add -b claude/video-trim-range .claude/worktrees/video-trim-range origin/main
cd .claude/worktrees/video-trim-range
git rev-parse --show-toplevel   # must end in .claude/worktrees/video-trim-range
git branch --show-current       # must be claude/video-trim-range
npm install
```

All remaining frontend steps run from this worktree.

- [ ] **Step 2: Write the failing tests**

In `src/data/board_images.test.ts`, add to the `youtubeEmbedUrl` describe block:

```ts
  it("appends whole-second start and end params", () => {
    const url = youtubeEmbedUrl("dQw4w9WgXcQ", {
      startSeconds: 45,
      endSeconds: 72,
    });
    expect(url).toContain("start=45");
    expect(url).toContain("end=72");
  });

  it("routes a trimmed clip through our own embed page even on web", () => {
    const url = youtubeEmbedUrl("dQw4w9WgXcQ", { endSeconds: 72 });
    expect(url).toContain("app.speakanyway.com/youtube-embed.html");
    expect(url).toContain("v=dQw4w9WgXcQ");
  });

  it("keeps embedding YouTube directly when there is no end bound", () => {
    const url = youtubeEmbedUrl("dQw4w9WgXcQ", { startSeconds: 45 });
    expect(url).toContain("youtube-nocookie.com/embed/dQw4w9WgXcQ");
    expect(url).toContain("start=45");
  });

  it("omits range params entirely when no range is given", () => {
    const url = youtubeEmbedUrl("dQw4w9WgXcQ", { autoplay: true });
    expect(url).not.toContain("start=");
    expect(url).not.toContain("end=");
  });
```

And a new describe block for the API client:

```ts
describe("attachYoutubeVideo", () => {
  it("sends range params only when they are supplied", async () => {
    const fetchMock = stubFetch(okResponse({ id: 1 }));
    seedAuthToken();

    await attachYoutubeVideo("7", "https://youtu.be/dQw4w9WgXcQ", {
      startSeconds: 45,
      endSeconds: 72,
    });
    expect(JSON.parse(String(fetchMock.mock.calls[0][1]?.body))).toEqual({
      url: "https://youtu.be/dQw4w9WgXcQ",
      start_seconds: 45,
      end_seconds: 72,
    });

    await attachYoutubeVideo("7", "https://youtu.be/dQw4w9WgXcQ");
    expect(JSON.parse(String(fetchMock.mock.calls[1][1]?.body))).toEqual({
      url: "https://youtu.be/dQw4w9WgXcQ",
    });
  });
});
```

Import `attachYoutubeVideo` and the helpers `okResponse`, `seedAuthToken`, `stubFetch` from `./__test-helpers` per the repo's testing standards.

- [ ] **Step 3: Run tests to verify they fail**

```bash
npx vitest run src/data/board_images.test.ts
```

Expected: FAIL — `startSeconds` is not a known option, range params absent.

- [ ] **Step 4: Write the implementation**

In `src/data/board_images.ts`, extend the interface:

```ts
export interface BoardImageVideo {
  source: "youtube" | "upload" | (string & {});
  youtube_id?: string; // youtube only — validated 11-char id
  url?: string; // upload only — CDN URL for the attached clip
  content_type?: string; // upload only
  start_seconds?: number; // optional trim point, whole seconds
  end_seconds?: number; // optional trim point, whole seconds
}
```

Replace `youtubeEmbedUrl`:

```ts
export const youtubeEmbedUrl = (
  youtubeId: string,
  opts: {
    autoplay?: boolean;
    proxied?: boolean;
    startSeconds?: number;
    endSeconds?: number;
  } = {},
) => {
  const { autoplay, proxied, startSeconds, endSeconds } = opts;
  // A trimmed clip always goes through our own page, on every platform: that
  // page owns the YouTube IFrame API and posts the end-of-clip signal back, so
  // there is one end-detection path rather than one per platform. Untrimmed
  // web embeds keep hitting YouTube directly, so nothing existing changes.
  const useProxy = Boolean(proxied) || endSeconds != null;
  const range =
    (startSeconds != null ? `&start=${Math.floor(startSeconds)}` : "") +
    (endSeconds != null ? `&end=${Math.floor(endSeconds)}` : "");

  if (useProxy) {
    return (
      `${YOUTUBE_EMBED_PROXY}?v=${encodeURIComponent(youtubeId)}` +
      (autoplay ? "&autoplay=1" : "") +
      range
    );
  }
  return (
    `https://www.youtube-nocookie.com/embed/${youtubeId}?rel=0` +
    (autoplay ? "&autoplay=1" : "") +
    range
  );
};
```

Note the non-proxied branch now always emits `?rel=0` so params append uniformly. If an existing test asserts the old exact string `?autoplay=1&rel=0`, update it to assert `toContain("autoplay=1")` and `toContain("rel=0")` — behavior is unchanged, only param order.

Replace `attachYoutubeVideo`:

```ts
export const attachYoutubeVideo = async (
  boardImageId: string,
  url: string,
  range: { startSeconds?: number | null; endSeconds?: number | null } = {},
) => {
  const body: Record<string, string | number> = { url };
  if (range.startSeconds != null) body.start_seconds = range.startSeconds;
  if (range.endSeconds != null) body.end_seconds = range.endSeconds;

  const response = await fetch(
    `${BASE_URL}board_images/${boardImageId}/attach_youtube_video`,
    {
      headers: signedInHeaders(),
      method: "POST",
      body: JSON.stringify(body),
    },
  );
  return response.json();
};
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
npx vitest run src/data/board_images.test.ts
```

Expected: PASS, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add src/data/board_images.ts src/data/board_images.test.ts
git commit -m "feat(video-tiles): trim range in the embed URL and API client"
```

---

## Task 5: Frontend — embed page drives the player and signals the end

**Files:**
- Modify: `public/youtube-embed.html`
- Test: `src/components/board_images/youtubeEmbedPage.test.ts`

**Interfaces:**
- Consumes: query params `v`, `autoplay`, `start`, `end` produced by `youtubeEmbedUrl` (Task 4).
- Produces: a `window.parent.postMessage({ type: "saw:video-ended" }, "*")` when playback reaches `end`. Task 6 listens for exactly that message type.

- [ ] **Step 1: Write the failing tests**

In `src/components/board_images/youtubeEmbedPage.test.ts`, following the file's existing pattern for loading and executing the real page, add:

```ts
  it("passes the trim range to the player", () => {
    const { player } = renderEmbedPage("?v=dQw4w9WgXcQ&start=45&end=72");
    expect(player.playerVars.start).toBe(45);
    expect(player.playerVars.end).toBe(72);
  });

  it("keeps the player on the nocookie host", () => {
    const { player } = renderEmbedPage("?v=dQw4w9WgXcQ&end=72");
    expect(player.host).toBe("https://www.youtube-nocookie.com");
  });

  it("posts an end signal to the parent when the clip ends", () => {
    const postMessage = vi.fn<(data: unknown, origin: string) => void>();
    const { fireEnded } = renderEmbedPage("?v=dQw4w9WgXcQ&end=72", { postMessage });

    fireEnded();
    expect(postMessage).toHaveBeenCalledWith({ type: "saw:video-ended" }, "*");
  });

  it("posts the end signal at most once", () => {
    const postMessage = vi.fn<(data: unknown, origin: string) => void>();
    const { fireEnded } = renderEmbedPage("?v=dQw4w9WgXcQ&end=72", { postMessage });

    fireEnded();
    fireEnded();
    expect(postMessage).toHaveBeenCalledTimes(1);
  });

  it("uses the plain iframe path when there is no end bound", () => {
    const { iframe, player } = renderEmbedPage("?v=dQw4w9WgXcQ&start=45");
    expect(player).toBeUndefined();
    expect(iframe?.getAttribute("src")).toContain("start=45");
  });

  it("still rejects a malformed video id", () => {
    const { iframe, player } = renderEmbedPage("?v=notavalidid&end=72");
    expect(player).toBeUndefined();
    expect(iframe).toBeNull();
    expect(document.body.textContent).toContain("isn't valid");
  });
```

Extend the file's existing test harness so `renderEmbedPage` stubs `window.YT` (a `Player` constructor capturing its config, plus `PlayerState.ENDED`), optionally stubs `window.parent.postMessage`, and returns `{ iframe, player, fireEnded }` where `fireEnded` invokes the captured `onStateChange` with `{ data: YT.PlayerState.ENDED }`.

- [ ] **Step 2: Run tests to verify they fail**

```bash
npx vitest run src/components/board_images/youtubeEmbedPage.test.ts
```

Expected: FAIL — no player is constructed, no message posted.

- [ ] **Step 3: Write the implementation**

In `public/youtube-embed.html`, replace the contents of the IIFE inside `<script>` (keep the surrounding HTML, styles, and the explanatory comment above it):

```js
      (() => {
        const params = new URLSearchParams(window.location.search);
        const videoId = params.get("v") || "";
        const autoplay = params.get("autoplay") === "1";

        const readSeconds = (name) => {
          const raw = params.get(name);
          if (raw === null || raw === "") return null;
          const value = Number(raw);
          return Number.isInteger(value) && value >= 0 ? value : null;
        };
        const start = readSeconds("start");
        const end = readSeconds("end");

        // Only ever build a URL from a well-formed YouTube id. This page is
        // publicly reachable, so an unvalidated value would let anyone frame
        // arbitrary content under our own domain.
        if (!/^[A-Za-z0-9_-]{11}$/.test(videoId)) {
          const p = document.createElement("p");
          p.className = "msg";
          p.textContent = "This video link isn't valid.";
          document.body.appendChild(p);
          return;
        }

        let notified = false;
        let pollTimer = null;
        const notifyEnded = () => {
          if (notified) return;
          notified = true;
          if (pollTimer !== null) clearInterval(pollTimer);
          // The payload carries nothing sensitive, and the parent origin
          // varies (capacitor://localhost on native, https on web), so "*"
          // is the only workable target. The parent verifies OUR origin.
          window.parent.postMessage({ type: "saw:video-ended" }, "*");
        };

        // No end bound: nothing to detect, so skip the API entirely and keep
        // the original lightweight iframe path.
        if (end === null) {
          const src =
            "https://www.youtube-nocookie.com/embed/" +
            videoId +
            "?rel=0&playsinline=1" +
            (autoplay ? "&autoplay=1" : "") +
            (start !== null ? "&start=" + start : "");

          const frame = document.createElement("iframe");
          frame.setAttribute("src", src);
          frame.setAttribute("title", "Video");
          frame.setAttribute(
            "allow",
            "autoplay; encrypted-media; picture-in-picture; fullscreen",
          );
          frame.setAttribute("allowfullscreen", "");
          frame.setAttribute("referrerpolicy", "strict-origin-when-cross-origin");
          document.body.appendChild(frame);
          return;
        }

        // Trimmed clip: drive the player through the IFrame API so we can tell
        // the parent when the slice is over.
        const holder = document.createElement("div");
        holder.id = "player";
        document.body.appendChild(holder);

        window.onYouTubeIframeAPIReady = () => {
          const player = new window.YT.Player("player", {
            // Keep the privacy posture — the API defaults to youtube.com.
            host: "https://www.youtube-nocookie.com",
            videoId: videoId,
            playerVars: {
              rel: 0,
              playsinline: 1,
              autoplay: autoplay ? 1 : 0,
              start: start !== null ? start : 0,
              end: end,
            },
            events: {
              onStateChange: (event) => {
                if (event.data === window.YT.PlayerState.ENDED) notifyEnded();
              },
            },
          });

          // `end` pauses rather than reporting ENDED in some clients, so poll
          // the position as a backstop. notifyEnded is idempotent and stops
          // this timer, so the poll never outlives the clip.
          pollTimer = setInterval(() => {
            if (typeof player.getCurrentTime !== "function") return;
            if (player.getCurrentTime() >= end) notifyEnded();
          }, 250);
        };

        const tag = document.createElement("script");
        tag.src = "https://www.youtube.com/iframe_api";
        document.head.appendChild(tag);
      })();
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npx vitest run src/components/board_images/youtubeEmbedPage.test.ts
```

Expected: PASS, 0 failures — including the pre-existing malformed-id and plain-iframe examples.

- [ ] **Step 5: Verify the CSP header still covers this page**

Read `public/_headers` lines 1–20. Confirm the `/youtube-embed.html` `frame-ancestors` rule still sits **above** the catch-all `X-Frame-Options: SAMEORIGIN`, and that its value permits framing from `https://app.speakanyway.com` (the web case, which now also frames this page) as well as the native scheme. Do not reorder the rules — the ordering was itself a bugfix (commit `03d533c9`). If the rule only lists the native origin, add the https app origin.

- [ ] **Step 6: Commit**

```bash
git add public/youtube-embed.html src/components/board_images/youtubeEmbedPage.test.ts public/_headers
git commit -m "feat(video-tiles): embed page honors trim range, signals clip end"
```

---

## Task 6: Frontend — playback modal closes at the end of the slice

**Files:**
- Modify: `src/components/board_images/TileVideoModal.tsx`
- Test: `src/components/board_images/TileVideoModal.test.tsx`

**Interfaces:**
- Consumes: `youtubeEmbedUrl` options from Task 4; the `{ type: "saw:video-ended" }` message from Task 5.
- Produces: no new exports. Behavior only.

- [ ] **Step 1: Write the failing tests**

In `src/components/board_images/TileVideoModal.test.tsx`, add:

```tsx
  const postEndSignal = (origin: string) => {
    window.dispatchEvent(
      new MessageEvent("message", {
        data: { type: "saw:video-ended" },
        origin,
      }),
    );
  };

  it("passes the trim range to the embed URL", () => {
    render(
      <TileVideoModal
        isOpen
        label="Sign for more"
        video={{
          source: "youtube",
          youtube_id: "dQw4w9WgXcQ",
          start_seconds: 45,
          end_seconds: 72,
        }}
        onClose={vi.fn()}
      />,
    );
    const src = screen.getByTitle("Sign for more").getAttribute("src") || "";
    expect(src).toContain("start=45");
    expect(src).toContain("end=72");
  });

  it("closes when the embed page reports the clip ended", async () => {
    const onClose = vi.fn();
    render(
      <TileVideoModal
        isOpen
        label="Sign for more"
        video={{ source: "youtube", youtube_id: "dQw4w9WgXcQ", end_seconds: 72 }}
        onClose={onClose}
      />,
    );

    postEndSignal("https://app.speakanyway.com");
    await waitFor(() => expect(onClose).toHaveBeenCalled());
  });

  it("ignores an end signal from any other origin", () => {
    const onClose = vi.fn();
    render(
      <TileVideoModal
        isOpen
        label="Sign for more"
        video={{ source: "youtube", youtube_id: "dQw4w9WgXcQ", end_seconds: 72 }}
        onClose={onClose}
      />,
    );

    postEndSignal("https://evil.example");
    expect(onClose).not.toHaveBeenCalled();
  });

  it("does not close an untrimmed video on a stray end signal", () => {
    const onClose = vi.fn();
    render(
      <TileVideoModal
        isOpen
        label="Sign for more"
        video={{ source: "youtube", youtube_id: "dQw4w9WgXcQ" }}
        onClose={onClose}
      />,
    );

    postEndSignal("https://app.speakanyway.com");
    expect(onClose).not.toHaveBeenCalled();
  });
```

These tests need the modal's content rendered; follow whatever `IonModal` setup the existing examples in this file already use.

- [ ] **Step 2: Run tests to verify they fail**

```bash
npx vitest run src/components/board_images/TileVideoModal.test.tsx
```

Expected: FAIL — no range in the src, `onClose` never called.

- [ ] **Step 3: Write the implementation**

In `src/components/board_images/TileVideoModal.tsx`, add below the imports:

```tsx
// The embed page's own origin — NOT ours. On native the app runs at
// capacitor://localhost while the page is served from https, so checking
// window.location.origin would reject every legitimate signal on device.
const EMBED_PAGE_ORIGIN = "https://app.speakanyway.com";
```

Add a second effect after the existing `isOpen` / online effect:

```tsx
  // A trimmed clip stops at end_seconds but the player just sits there, so the
  // embed page tells us when the slice is over and we dismiss. Only trimmed
  // YouTube videos listen — nothing else can produce this signal.
  useEffect(() => {
    if (!isOpen) return;
    if (video?.source !== "youtube" || video.end_seconds == null) return;

    const handleMessage = (event: MessageEvent) => {
      if (event.origin !== EMBED_PAGE_ORIGIN) return;
      const payload = event.data as { type?: string } | null;
      if (payload?.type === "saw:video-ended") onClose();
    };
    window.addEventListener("message", handleMessage);
    return () => window.removeEventListener("message", handleMessage);
  }, [isOpen, video, onClose]);
```

And pass the range through in `renderPlayer`:

```tsx
            src={youtubeEmbedUrl(video.youtube_id, {
              autoplay: true,
              proxied: Capacitor.isNativePlatform(),
              startSeconds: video.start_seconds,
              endSeconds: video.end_seconds,
            })}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npx vitest run src/components/board_images/TileVideoModal.test.tsx
```

Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add src/components/board_images/TileVideoModal.tsx src/components/board_images/TileVideoModal.test.tsx
git commit -m "feat(video-tiles): close the player when a trimmed clip ends"
```

---

## Task 7: Frontend — Start/End fields in the tile editor

**Files:**
- Create: `src/components/utils/parseTimecode.ts`
- Create: `src/components/utils/parseTimecode.test.ts`
- Modify: `src/components/board_images/BoardImageVideoTab.tsx`
- Modify: `src/locales/en.json`, `src/locales/es.json`
- Test: `src/components/board_images/BoardImageVideoTab.test.tsx`

**Interfaces:**
- Consumes: `attachYoutubeVideo(id, url, range)` from Task 4.
- Produces: `parseTimecodeSeconds(raw: string): TimecodeResult`.

- [ ] **Step 1: Write the failing parser test**

Create `src/components/utils/parseTimecode.test.ts`:

```ts
// @vitest-environment node
import { describe, expect, it } from "vitest";
import { parseTimecodeSeconds } from "./parseTimecode";

describe("parseTimecodeSeconds", () => {
  it("treats blank input as cleared, not invalid", () => {
    expect(parseTimecodeSeconds("")).toEqual({ ok: true, seconds: null });
    expect(parseTimecodeSeconds("   ")).toEqual({ ok: true, seconds: null });
  });

  it.each([
    ["83", 83],
    ["0", 0],
    ["1:23", 83],
    ["0:07", 7],
    ["10:00", 600],
  ])("parses %s as %i seconds", (raw, expected) => {
    expect(parseTimecodeSeconds(raw)).toEqual({ ok: true, seconds: expected });
  });

  it.each(["abc", "1:2:3", "-5", "1.5", "1:75", ":30", "1:"])(
    "rejects %s",
    (raw) => {
      expect(parseTimecodeSeconds(raw)).toEqual({ ok: false });
    },
  );
});
```

- [ ] **Step 2: Run it to verify it fails**

```bash
npx vitest run src/components/utils/parseTimecode.test.ts
```

Expected: FAIL — module not found.

- [ ] **Step 3: Write the parser**

Create `src/components/utils/parseTimecode.ts`:

```ts
// Parses a trim-point field into whole seconds. Accepts "1:23" or a raw "83".
//
// Blank is a valid, meaningful value ("no bound"), so it is reported as
// ok with seconds: null rather than as an error — a caregiver clearing the
// field must not see a validation complaint.
export type TimecodeResult =
  | { ok: true; seconds: number | null }
  | { ok: false };

export const parseTimecodeSeconds = (raw: string): TimecodeResult => {
  const trimmed = raw.trim();
  if (!trimmed) return { ok: true, seconds: null };

  const parts = trimmed.split(":");
  if (parts.length > 2) return { ok: false };
  if (!parts.every((part) => /^\d+$/.test(part))) return { ok: false };

  if (parts.length === 2) {
    const [minutes, seconds] = parts.map(Number);
    if (seconds > 59) return { ok: false };
    return { ok: true, seconds: minutes * 60 + seconds };
  }
  return { ok: true, seconds: Number(parts[0]) };
};
```

- [ ] **Step 4: Run it to verify it passes**

```bash
npx vitest run src/components/utils/parseTimecode.test.ts
```

Expected: PASS, 0 failures.

- [ ] **Step 5: Add the locale strings**

In `src/locales/en.json`, inside `board_view.image_modal.video`, add after `"youtube_save"`:

```json
        "range_heading": "Play only part of the video",
        "range_hint": "Optional. Use 1:23 or seconds. Leave blank to play the whole video.",
        "start_label": "Start at",
        "end_label": "End at",
        "error_invalid_range": "Please check the start and end times. The end must come after the start.",
```

Add the matching Spanish keys to `src/locales/es.json` in the same block:

```json
        "range_heading": "Reproducir solo una parte del video",
        "range_hint": "Opcional. Usa 1:23 o segundos. Déjalo en blanco para reproducir todo el video.",
        "start_label": "Comenzar en",
        "end_label": "Terminar en",
        "error_invalid_range": "Revisa los tiempos de inicio y fin. El fin debe ser posterior al inicio.",
```

- [ ] **Step 6: Write the failing component tests**

In `src/components/board_images/BoardImageVideoTab.test.tsx`, add:

```tsx
  it("sends the parsed range when saving a link", async () => {
    const attach = vi.mocked(attachYoutubeVideo);
    attach.mockResolvedValue({ id: 1, data: {} } as BoardImage);
    renderTab();

    await userEvent.type(
      screen.getByLabelText("YouTube link"),
      "https://youtu.be/dQw4w9WgXcQ",
    );
    await userEvent.type(screen.getByLabelText("Start at"), "1:23");
    await userEvent.type(screen.getByLabelText("End at"), "2:00");
    await userEvent.click(screen.getByText("Save link"));

    await waitFor(() =>
      expect(attach).toHaveBeenCalledWith(
        expect.anything(),
        "https://youtu.be/dQw4w9WgXcQ",
        { startSeconds: 83, endSeconds: 120 },
      ),
    );
  });

  it("sends no range when the fields are left blank", async () => {
    const attach = vi.mocked(attachYoutubeVideo);
    attach.mockResolvedValue({ id: 1, data: {} } as BoardImage);
    renderTab();

    await userEvent.type(
      screen.getByLabelText("YouTube link"),
      "https://youtu.be/dQw4w9WgXcQ",
    );
    await userEvent.click(screen.getByText("Save link"));

    await waitFor(() =>
      expect(attach).toHaveBeenCalledWith(expect.anything(), expect.any(String), {
        startSeconds: null,
        endSeconds: null,
      }),
    );
  });

  it("rejects an unparseable time without calling the API", async () => {
    const attach = vi.mocked(attachYoutubeVideo);
    renderTab();

    await userEvent.type(
      screen.getByLabelText("YouTube link"),
      "https://youtu.be/dQw4w9WgXcQ",
    );
    await userEvent.type(screen.getByLabelText("Start at"), "banana");
    await userEvent.click(screen.getByText("Save link"));

    expect(attach).not.toHaveBeenCalled();
  });

  it("rejects an end that is not after the start without calling the API", async () => {
    const attach = vi.mocked(attachYoutubeVideo);
    renderTab();

    await userEvent.type(
      screen.getByLabelText("YouTube link"),
      "https://youtu.be/dQw4w9WgXcQ",
    );
    await userEvent.type(screen.getByLabelText("Start at"), "2:00");
    await userEvent.type(screen.getByLabelText("End at"), "1:00");
    await userEvent.click(screen.getByText("Save link"));

    expect(attach).not.toHaveBeenCalled();
  });

  it("saves a range change on an already-attached video without re-pasting the link", async () => {
    const attach = vi.mocked(attachYoutubeVideo);
    attach.mockResolvedValue({ id: 1, data: {} } as BoardImage);
    renderTab({
      data: { video: { source: "youtube", youtube_id: "dQw4w9WgXcQ" } },
    });

    await userEvent.type(screen.getByLabelText("Start at"), "0:30");
    await userEvent.click(screen.getByText("Save link"));

    await waitFor(() =>
      expect(attach).toHaveBeenCalledWith(
        expect.anything(),
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        { startSeconds: 30, endSeconds: null },
      ),
    );
  });
```

Match the file's existing `renderTab` helper and mocking setup; extend `renderTab` to accept optional board-image overrides if it does not already.

- [ ] **Step 7: Run them to verify they fail**

```bash
npx vitest run src/components/board_images/BoardImageVideoTab.test.tsx
```

Expected: FAIL — no "Start at" / "End at" fields exist.

- [ ] **Step 8: Wire the fields into the tab**

In `src/components/board_images/BoardImageVideoTab.tsx`:

Add the import:

```tsx
import { parseTimecodeSeconds } from "../utils/parseTimecode";
```

Add state alongside `youtubeUrl`, seeded from any already-saved range:

```tsx
  const savedVideo = boardImage.data?.video;
  const [startText, setStartText] = useState(
    savedVideo?.start_seconds != null ? String(savedVideo.start_seconds) : "",
  );
  const [endText, setEndText] = useState(
    savedVideo?.end_seconds != null ? String(savedVideo.end_seconds) : "",
  );
```

Replace `handleAttachYoutube`:

```tsx
  const handleAttachYoutube = async () => {
    // An already-attached video can have its range edited without re-pasting
    // the link: only the 11-char id is stored, so rebuild a URL from it and
    // send that back through the same validated endpoint.
    const typed = youtubeUrl.trim();
    const url =
      typed ||
      (video?.source === "youtube" && video.youtube_id
        ? `https://www.youtube.com/watch?v=${video.youtube_id}`
        : "");
    if (!url) return;

    const start = parseTimecodeSeconds(startText);
    const end = parseTimecodeSeconds(endText);
    if (!start.ok || !end.ok) {
      toast(t("board_view.image_modal.video.error_invalid_range"));
      return;
    }
    if (
      start.seconds != null &&
      end.seconds != null &&
      end.seconds <= start.seconds
    ) {
      toast(t("board_view.image_modal.video.error_invalid_range"));
      return;
    }

    setBusy(true);
    try {
      const result = await attachYoutubeVideo(boardImageId, url, {
        startSeconds: start.seconds,
        endSeconds: end.seconds,
      });
      if (!result || result.error) {
        toast(
          result?.error === "invalid_video_range"
            ? t("board_view.image_modal.video.error_invalid_range")
            : t("board_view.image_modal.video.error_invalid_url"),
        );
        return;
      }
      applyUpdated(result);
      setYoutubeUrl("");
      toast(t("board_view.image_modal.video.toast_attached"));
    } catch {
      toast(t("board_view.image_modal.video.error_generic"));
    } finally {
      setBusy(false);
    }
  };
```

Enable the Save button when a range edit is possible on an existing video — replace the button's `disabled` prop:

```tsx
            disabled={
              busy ||
              (!youtubeUrl.trim() &&
                !(video?.source === "youtube" && video.youtube_id))
            }
```

Add the range fields inside the YouTube `<section>`, directly below the URL input's wrapping `<div>`:

```tsx
        <div className="mt-3">
          <h3 className="text-xs font-bold text-brand-ink">
            {t("board_view.image_modal.video.range_heading")}
          </h3>
          <p className="mb-2 text-xs text-brand-muted">
            {t("board_view.image_modal.video.range_hint")}
          </p>
          <div className="flex flex-wrap items-center gap-2">
            <input
              type="text"
              inputMode="numeric"
              value={startText}
              disabled={busy}
              onChange={(e) => setStartText(e.target.value)}
              placeholder="0:00"
              aria-label={t("board_view.image_modal.video.start_label")}
              className="w-24 rounded-xl border border-brand-line px-3 py-2"
            />
            <input
              type="text"
              inputMode="numeric"
              value={endText}
              disabled={busy}
              onChange={(e) => setEndText(e.target.value)}
              placeholder="1:30"
              aria-label={t("board_view.image_modal.video.end_label")}
              className="w-24 rounded-xl border border-brand-line px-3 py-2"
            />
          </div>
        </div>
```

Pass the saved range into the preview iframe in `currentVideoSummary`:

```tsx
              src={youtubeEmbedUrl(video.youtube_id, {
                proxied: Capacitor.isNativePlatform(),
                startSeconds: video.start_seconds,
                endSeconds: video.end_seconds,
              })}
```

- [ ] **Step 9: Run the tests**

```bash
npx vitest run src/components/board_images/BoardImageVideoTab.test.tsx src/components/utils/parseTimecode.test.ts
```

Expected: PASS, 0 failures.

- [ ] **Step 10: Run the full frontend video suite and the build**

```bash
npx vitest run src/components/board_images src/data/board_images.test.ts src/components/utils
npm run build
```

Expected: both PASS. `npm run build` runs `tsc` over the whole `src` tree including tests — per this repo's testing standards, vitest alone does **not** type-check, so a green vitest with a red build is the expected failure mode if a mock lacks an explicit signature.

- [ ] **Step 11: Commit and push**

```bash
git add src/components/utils/parseTimecode.ts src/components/utils/parseTimecode.test.ts \
        src/components/board_images/BoardImageVideoTab.tsx \
        src/components/board_images/BoardImageVideoTab.test.tsx \
        src/locales/en.json src/locales/es.json
git commit -m "feat(video-tiles): start/end trim fields in the tile editor"
git push -u origin claude/video-trim-range
```

---

## Task 8: Docs and PR

**Files:**
- Modify: `itty_bitty_boards/CLAUDE.md` (Video stack bullet)
- Modify: `itty-bitty-frontend/.claude-notes/` if a video note exists there

- [ ] **Step 1: Update the backend video documentation**

In the backend worktree, extend the **Video (tile clips)** bullet in `CLAUDE.md` with one sentence:

```
  YouTube tiles may carry optional `start_seconds`/`end_seconds` trim points in
  `data["video"]`; they are validated by `BoardImage.parse_video_range` and
  written only via `attach_youtube_video`.
```

Keep it to that — per the repo's documentation rules the hub stays lean, and the detail already lives in `.claude-notes/video-tile-trim-range.md`.

- [ ] **Step 2: Commit the docs**

```bash
git add CLAUDE.md
git commit -m "docs: note the video trim range in the hub"
git push
```

- [ ] **Step 3: Open both PRs**

Backend first (it is independently shippable), then frontend. Use the `pr` skill. Each PR body: short summary plus the test plan — the exact rspec/vitest commands run and their results.

No `CHANGELOG.md` entry: the Video tab is still gated to admins, so this is not user-facing yet. Say so explicitly in the frontend PR body.

---

## Manual verification (after both PRs merge to staging)

Automated tests cannot cover the real YouTube player. Check by hand on staging:

1. Attach a YouTube link with start `1:00` and end `1:10` to a tile. Save.
2. Editor preview starts at 1:00.
3. In use mode, tap the tile — the label speaks, then the video opens, plays 1:00→1:10, and the modal closes on its own.
4. Repeat on a native build. The clip must load (no "Error 153") and still auto-close.
5. Attach a link with no range. It must play in full and require a manual close, exactly as before.
