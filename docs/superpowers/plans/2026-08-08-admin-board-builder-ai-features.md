# Admin Board Builder AI Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the admin Board Builder AI drafting of a whole linked board set, AI-suggested description and tags, and four quality-of-life actions on the build page.

**Architecture:** Every AI feature is a plain service object under `app/services/boards/admin_builder/` that takes primitives, makes one OpenAI call, sanitizes what comes back, and returns plain data. None of them touch the database. `Admin::BoardBuildsController` calls them and merges the result into `@form`, then re-renders `new` — the same shape the existing `suggest` and `draft` actions already use. Persistence happens only in `create` (which writes an `AdminBoardBuild`) and `Boards::AdminBuilder::Build` (which writes the boards).

**Tech Stack:** Rails 8, RSpec + FactoryBot, Sidekiq, `ruby-openai` via the app's `OpenAiClient` wrapper, ERB views with Tailwind classes.

**Spec:** `docs/superpowers/specs/2026-08-08-admin-board-builder-ai-features-design.md`

## Global Constraints

- **AI only ever fills the form.** No new AI path may create or update a record. A human edits the form, previews the art, then builds.
- **Preview writes nothing.** The request spec asserts `preview` changes neither `Board.count` nor `Image.count`. Do not break it.
- **Every board-touching member action is scoped through `AdminBoardBuild.builder_boards`** so a hand-edited `board_id` can never reach an unrelated board.
- **Never let a spec reach the real OpenAI API.** Stub with `allow_any_instance_of(OpenAiClient).to receive(:create_chat)`.
- **Parts of speech come from `ColorHelper::PARTS_OF_SPEECH`**: `adjective, verb, pronoun, noun, conjunction, preposition, social, question, adverb, important_function, determiner, default`. Anything else is coerced to `"default"`.
- **Tags are normalized with `Board.normalize_tag_value`** (lowercase, whitespace squeezed) — always, on every path.
- **`description` and `tags` are applied to the ROOT board only.** Child pages are created with `predefined: false` and are not in the public catalogue; tagging them would pollute `Board.public_boards_tags`.
- **Page keys must match `/\A[a-z0-9_]+\z/`** — `PlanValidator#key_problems` rejects anything else.
- **Child pages must carry no `columns`/`rows`** so they inherit the root grid and `PlanValidator#grid_problems` stays quiet.
- Specs needing the seed admin use `User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)`.
- Commit messages use Conventional Commit prefixes.
- Run tests with `bundle exec rspec <path>`.

---

# Phase 1 — Word list serializer and whole-set drafting

### Task 1: `Boards::AdminBuilder::WordList`

The textarea format (`label | part_of_speech | display text | >page_key`) is currently parsed in the controller and rendered in two other places, each dropping different fields. Task 2 needs to *emit* `>key` tokens and Task 9 needs a faithful round-trip, so both directions move into one module.

**Files:**
- Create: `app/services/boards/admin_builder/word_list.rb`
- Modify: `app/controllers/admin/board_builds_controller.rb` (delete `parse_tiles` at 362-378 and `tiles_to_words` at 274-276; delete `LINK_TOKEN` at 24)
- Modify: `app/views/admin/board_builds/show.html.erb:140-144`
- Test: `spec/services/boards/admin_builder/word_list_spec.rb`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `Boards::AdminBuilder::WordList.parse(text) -> Array<Hash>` — each tile `{ label: String, part_of_speech: String, display_label: String?, links_to: String? }`, with `display_label` and `links_to` absent (not nil) when empty. `part_of_speech` is always present, defaulting to `"default"`.
  - `Boards::AdminBuilder::WordList.render(tiles) -> String` — newline-joined; accepts symbol- or string-keyed hashes.
  - `Boards::AdminBuilder::WordList::LINK_TOKEN == ">"`

- [ ] **Step 1: Write the failing test**

Create `spec/services/boards/admin_builder/word_list_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Boards::AdminBuilder::WordList do
  describe ".parse" do
    it "reads a bare word as a default-coloured tile" do
      expect(described_class.parse("swing")).to eq([{ label: "swing", part_of_speech: "default" }])
    end

    it "reads a part of speech and tile text" do
      expect(described_class.parse("food | noun | Snacks"))
        .to eq([{ label: "food", part_of_speech: "noun", display_label: "Snacks" }])
    end

    it "finds the link field wherever it appears in the line" do
      expect(described_class.parse("Food | noun | >food"))
        .to eq([{ label: "Food", part_of_speech: "noun", links_to: "food" }])
    end

    it "downcases a link target and drops blank lines" do
      expect(described_class.parse("back | social | >__ROOT__\n\n  \n"))
        .to eq([{ label: "back", part_of_speech: "social", links_to: "__root__" }])
    end
  end

  describe ".render" do
    it "always emits the part of speech" do
      expect(described_class.render([{ label: "swing", part_of_speech: "noun" }])).to eq("swing | noun")
    end

    it "defaults a missing part of speech" do
      expect(described_class.render([{ label: "swing" }])).to eq("swing | default")
    end

    it "emits a link without forcing an empty tile-text field" do
      expect(described_class.render([{ label: "Food", part_of_speech: "noun", links_to: "food" }]))
        .to eq("Food | noun | >food")
    end

    it "emits tile text and a link together, in that order" do
      expect(described_class.render([{ label: "Food", part_of_speech: "noun", display_label: "Snacks", links_to: "food" }]))
        .to eq("Food | noun | Snacks | >food")
    end

    it "accepts string-keyed tiles as stored in the plan jsonb" do
      expect(described_class.render([{ "label" => "swing", "part_of_speech" => "noun" }])).to eq("swing | noun")
    end

    it "joins tiles with newlines" do
      tiles = [{ label: "I", part_of_speech: "pronoun" }, { label: "want", part_of_speech: "verb" }]
      expect(described_class.render(tiles)).to eq("I | pronoun\nwant | verb")
    end
  end

  # The round trip is what Task 9 (duplicate a build into the form) depends on.
  describe "round trip" do
    it "survives every combination of the optional fields" do
      tiles = [
        { label: "I", part_of_speech: "pronoun" },
        { label: "food", part_of_speech: "noun", display_label: "Snacks" },
        { label: "Food", part_of_speech: "noun", links_to: "food" },
        { label: "Home", part_of_speech: "social", display_label: "Back", links_to: "__root__" },
      ]

      expect(described_class.parse(described_class.render(tiles))).to eq(tiles)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/boards/admin_builder/word_list_spec.rb`
Expected: FAIL with `uninitialized constant Boards::AdminBuilder::WordList`

- [ ] **Step 3: Write the module**

Create `app/services/boards/admin_builder/word_list.rb`:

```ruby
module Boards
  module AdminBuilder
    # The builder's textarea format, both directions.
    #
    # One tile per line: `word`, `word | part_of_speech`,
    # `word | part_of_speech | tile text`, and a field beginning with `>` names
    # the page the tile opens — wherever in the line it appears, so
    # `Food | noun | >food` doesn't force an empty tile-text field just to reach
    # a fourth position.
    #
    # Parsing and rendering live together because `.render` has to be the exact
    # inverse of `.parse`: the AI set drafter emits link tokens, and duplicating
    # a past build back into the form round-trips a stored plan through both.
    #
    # Known limit of the format, not of this code: tile text that itself starts
    # with `>` parses back as a link. Not worth escaping — no AAC tile reads
    # that way.
    module WordList
      LINK_TOKEN = ">".freeze

      module_function

      def parse(text)
        text.to_s.split("\n").filter_map do |line|
          line = line.strip
          next if line.blank?

          label, *rest = line.split("|").map { |part| part.to_s.strip }
          links_to = rest.find { |field| field.start_with?(LINK_TOKEN) }
          part_of_speech, display_label = rest - [links_to].compact

          {
            label: label.to_s,
            part_of_speech: part_of_speech.presence || "default",
            display_label: display_label.presence,
            links_to: links_to&.delete_prefix(LINK_TOKEN)&.strip&.downcase.presence,
          }.compact
        end
      end

      def render(tiles)
        Array(tiles).map { |tile| render_tile(tile) }.join("\n")
      end

      # The part of speech is always emitted, even when it's "default" — the
      # line round-trips either way, and a uniform shape reads better in a
      # textarea of 84 lines than a ragged one.
      def render_tile(tile)
        tile = tile.symbolize_keys
        fields = [tile[:label].to_s, tile[:part_of_speech].presence || "default"]
        fields << tile[:display_label].to_s if tile[:display_label].present?
        fields << "#{LINK_TOKEN}#{tile[:links_to]}" if tile[:links_to].present?
        fields.join(" | ")
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/services/boards/admin_builder/word_list_spec.rb`
Expected: PASS (14 examples)

- [ ] **Step 5: Point the controller at the module**

In `app/controllers/admin/board_builds_controller.rb`:

Delete the `LINK_TOKEN` constant and its comment (lines 23-24).

Replace the body of `tiles_to_words`:

```ruby
    def tiles_to_words(tiles)
      Boards::AdminBuilder::WordList.render(tiles)
    end
```

Replace `parse_tiles` (and delete its long comment, which now lives on the module):

```ruby
    def parse_tiles(words)
      Boards::AdminBuilder::WordList.parse(words)
    end
```

- [ ] **Step 6: Point the show view at the module**

In `app/views/admin/board_builds/show.html.erb`, replace lines 140-144 with:

```erb
    <pre class="text-[11px] text-t2 font-mono whitespace-pre-wrap"><%= Boards::AdminBuilder::WordList.render(page[:tiles]) %></pre>
```

- [ ] **Step 7: Run the surrounding suites**

Run: `bundle exec rspec spec/services/boards/admin_builder spec/requests/admin/board_builds_spec.rb`
Expected: PASS, no regressions.

- [ ] **Step 8: Commit**

```bash
git add app/services/boards/admin_builder/word_list.rb spec/services/boards/admin_builder/word_list_spec.rb app/controllers/admin/board_builds_controller.rb app/views/admin/board_builds/show.html.erb
git commit -m "refactor(admin): move the builder word-list format into one module"
```

---

### Task 2: `Boards::AdminBuilder::SetDrafter`

**Files:**
- Create: `app/services/boards/admin_builder/set_drafter.rb`
- Test: `spec/services/boards/admin_builder/set_drafter_spec.rb`

**Interfaces:**
- Consumes: `Boards::AdminBuilder::WordList` (Task 1) is *not* used here — this returns tile hashes, not text. `Boards::AdminBuilder::WordListDrafter` (existing) and `Boards::AdminBuilder::Plan::ROOT_KEY` (existing, `"__root__"`).
- Produces:
  - `Boards::AdminBuilder::SetDrafter.new(topic:, columns:, rows:, page_count:, audience: nil).call -> { root_tiles: Array<Hash>, children: Array<{ key: String, name: String, tiles: Array<Hash> }> }`
  - Tile hashes are the same shape `WordList.parse` produces.
  - `Boards::AdminBuilder::SetDrafter::GenerationError`
  - `Boards::AdminBuilder::SetDrafter::MAX_PAGES == 4`

- [ ] **Step 1: Write the failing test**

Create `spec/services/boards/admin_builder/set_drafter_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Boards::AdminBuilder::SetDrafter do
  def tile(label, pos, links_to = nil)
    { "label" => label, "part_of_speech" => pos }.tap { |t| t["links_to"] = links_to if links_to }
  end

  def ai_set(root:, pages: [])
    { "root" => root, "pages" => pages }.to_json
  end

  def stub_ai(content)
    allow_any_instance_of(OpenAiClient).to receive(:create_chat)
      .and_return({ role: "assistant", content: content })
  end

  let(:valid_set) do
    ai_set(
      root: [tile("I", "pronoun"), tile("want", "verb"), tile("more", "social"), tile("Food", "noun", "food")],
      pages: [
        {
          "key" => "food",
          "name" => "Food",
          "tiles" => [tile("apple", "noun"), tile("hungry", "adjective"),
                      tile("eat", "verb"), tile("back", "social", "__root__")],
        },
      ],
    )
  end

  before { stub_ai(valid_set) }

  def draft(**overrides)
    described_class.new(**{ topic: "the playground", columns: 2, rows: 2, page_count: 1 }.merge(overrides)).call
  end

  describe "#call" do
    it "returns the root tiles and one child page" do
      result = draft

      expect(result[:root_tiles]).to eq([
        { label: "I", part_of_speech: "pronoun" },
        { label: "want", part_of_speech: "verb" },
        { label: "more", part_of_speech: "social" },
        { label: "Food", part_of_speech: "noun", links_to: "food" },
      ])
      expect(result[:children].size).to eq(1)
      expect(result[:children].first[:key]).to eq("food")
      expect(result[:children].first[:name]).to eq("Food")
      expect(result[:children].first[:tiles].last)
        .to eq({ label: "back", part_of_speech: "social", links_to: "__root__" })
    end

    it "refuses to draft without a topic" do
      expect { draft(topic: "  ") }.to raise_error(described_class::GenerationError, /topic/)
    end

    # A page count of zero is a single-board draft. Asking a second prompt for
    # what WordListDrafter already does would be paying twice for one answer.
    it "delegates a zero-page draft to WordListDrafter" do
      expect(Boards::AdminBuilder::WordListDrafter).to receive(:new)
        .with(topic: "the playground", columns: 2, rows: 2, audience: nil)
        .and_return(instance_double(Boards::AdminBuilder::WordListDrafter,
                                    call: [{ label: "swing", part_of_speech: "noun" }]))

      expect(draft(page_count: 0)).to eq(
        { root_tiles: [{ label: "swing", part_of_speech: "noun" }], children: [] },
      )
    end

    it "re-raises a delegated drafter failure as its own error" do
      allow(Boards::AdminBuilder::WordListDrafter).to receive(:new).and_raise(
        Boards::AdminBuilder::WordListDrafter::GenerationError, "no usable words",
      )

      expect { draft(page_count: 0) }.to raise_error(described_class::GenerationError, /no usable words/)
    end
  end

  describe "cleanup of what the model returns" do
    it "drops a link pointing at a page that isn't in the set" do
      stub_ai(ai_set(root: [tile("Toys", "noun", "toys")], pages: []))

      expect(draft(columns: 1, rows: 1, page_count: 1)[:root_tiles])
        .to eq([{ label: "Toys", part_of_speech: "noun" }])
    end

    it "keeps a child's link back to the root" do
      stub_ai(ai_set(root: [tile("Food", "noun", "food")],
                     pages: [{ "key" => "food", "name" => "Food", "tiles" => [tile("back", "social", "__root__")] }]))

      expect(draft(columns: 1, rows: 1)[:children].first[:tiles].first[:links_to]).to eq("__root__")
    end

    # The root linking to itself would build a tile that opens the board it is
    # already on.
    it "drops a root tile linking to the root" do
      stub_ai(ai_set(root: [tile("Home", "social", "__root__")], pages: []))

      expect(draft(columns: 1, rows: 1)[:root_tiles]).to eq([{ label: "Home", part_of_speech: "social" }])
    end

    it "normalizes a page key to lowercase letters, numbers and underscores" do
      stub_ai(ai_set(root: [tile("Food", "noun", "food")],
                     pages: [{ "key" => "Food Time!", "name" => "Food", "tiles" => [tile("apple", "noun")] }]))

      expect(draft(columns: 1, rows: 1)[:children].first[:key]).to eq("food_time")
    end

    it "drops a page with no usable key" do
      stub_ai(ai_set(root: [tile("I", "pronoun")],
                     pages: [{ "key" => "  ", "name" => "Food", "tiles" => [tile("apple", "noun")] }]))

      expect(draft(columns: 1, rows: 1)[:children]).to be_empty
    end

    it "drops a page whose key repeats an earlier one" do
      stub_ai(ai_set(root: [tile("I", "pronoun")],
                     pages: [
                       { "key" => "food", "name" => "Food", "tiles" => [tile("apple", "noun")] },
                       { "key" => "food", "name" => "More Food", "tiles" => [tile("pear", "noun")] },
                     ]))

      children = draft(columns: 1, rows: 1, page_count: 2)[:children]
      expect(children.map { |child| child[:name] }).to eq(["Food"])
    end

    it "drops a casing-only duplicate within a page" do
      stub_ai(ai_set(root: [tile("go", "verb"), tile("Go", "verb"), tile("stop", "important_function")], pages: []))

      expect(draft(columns: 3, rows: 1, page_count: 1)[:root_tiles].map { |t| t[:label] })
        .to eq(%w[go stop])
    end

    it "falls back to default for a part of speech outside the Fitzgerald key" do
      stub_ai(ai_set(root: [tile("swing", "gerund")], pages: []))

      expect(draft(columns: 1, rows: 1)[:root_tiles].first[:part_of_speech]).to eq("default")
    end

    it "trims a page longer than the grid" do
      stub_ai(ai_set(root: [tile("I", "pronoun"), tile("want", "verb"), tile("more", "social")], pages: []))

      expect(draft(columns: 1, rows: 2)[:root_tiles].size).to eq(2)
    end

    # Same tolerance as WordListDrafter: this only fills a form, and the
    # counter shows the gap.
    it "returns a short draft rather than raising" do
      stub_ai(ai_set(root: [tile("I", "pronoun")], pages: []))

      expect(draft(columns: 3, rows: 3)[:root_tiles].size).to eq(1)
    end
  end

  describe "failures" do
    it "raises when OpenAI returns nothing" do
      stub_ai("")
      expect { draft }.to raise_error(described_class::GenerationError, /no content/)
    end

    it "raises on unparseable JSON" do
      stub_ai("not json")
      expect { draft }.to raise_error(described_class::GenerationError, /Failed to parse/)
    end

    it "raises when the root came back empty" do
      stub_ai(ai_set(root: [], pages: []))
      expect { draft }.to raise_error(described_class::GenerationError, /no usable words/)
    end
  end

  describe "the prompt" do
    def prompt_for(**args)
      captured = nil
      allow(OpenAiClient).to receive(:new) do |opts|
        captured = opts[:messages].first[:content]
        instance_double(OpenAiClient, create_chat: { role: "assistant", content: valid_set })
          .tap { |double| allow(double).to receive(:instance_variable_set) }
      end
      described_class.new(**{ topic: "the playground", columns: 6, rows: 4, page_count: 2 }.merge(args)).call
      captured
    end

    it "asks for exactly the grid's worth of tiles on every page" do
      expect(prompt_for).to include("EXACTLY 24 tiles")
    end

    it "asks for the requested number of pages" do
      expect(prompt_for).to include("exactly 2 pages")
    end

    it "requires a folder tile on the root for every page" do
      expect(prompt_for).to include("one tile on the main board that opens it")
    end

    it "requires a way back from every page" do
      expect(prompt_for).to include(Boards::AdminBuilder::Plan::ROOT_KEY)
    end

    it "constrains the part of speech to the Fitzgerald key" do
      expect(prompt_for).to include(ColorHelper::PARTS_OF_SPEECH.join(", "))
    end

    it "includes the audience only when one is given" do
      expect(prompt_for(audience: "a preschooler")).to include("It is for: a preschooler")
      expect(prompt_for).not_to include("It is for:")
    end

    it "caps the page count it will ask for" do
      expect(prompt_for(page_count: 99)).to include("exactly #{described_class::MAX_PAGES} pages")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/boards/admin_builder/set_drafter_spec.rb`
Expected: FAIL with `uninitialized constant Boards::AdminBuilder::SetDrafter`

- [ ] **Step 3: Write the service**

Create `app/services/boards/admin_builder/set_drafter.rb`:

```ruby
module Boards
  module AdminBuilder
    # Drafts a whole linked board set in one OpenAI call: the root word list
    # with its folder tiles already carrying link targets, plus each child
    # page's key, name and word list.
    #
    # The output ONLY EVER POPULATES THE FORM, like WordListDrafter. A human
    # edits it, previews the art, then builds.
    #
    # Two rules of PlanValidator decide the prompt's shape and must be honoured
    # here rather than discovered at preview:
    #   * every page must exactly fill its grid, so the per-page tile count is
    #     stated explicitly;
    #   * every page shares the root's grid, so a child is never given a grid
    #     of its own.
    #
    # No credit charge: the boards it drafts are admin-owned.
    class SetDrafter
      class GenerationError < StandardError; end

      # More pages than this in one call and the response gets long enough that
      # the per-page tile counts start slipping.
      MAX_PAGES = 4
      # 12x12, matching the controller's grid ceiling.
      MAX_TILES_PER_PAGE = 144

      def initialize(topic:, columns:, rows:, page_count:, audience: nil)
        @topic = topic.to_s.strip
        @tile_count = (columns.to_i * rows.to_i).clamp(1, MAX_TILES_PER_PAGE)
        @page_count = page_count.to_i.clamp(0, MAX_PAGES)
        @audience = audience.to_s.strip
        @columns = columns.to_i
        @rows = rows.to_i
      end

      def call
        raise GenerationError, "give the board a topic to draft from" if topic.blank?
        return single_page_set if page_count.zero?

        parse_response(generate_via_openai)
      end

      private

      attr_reader :topic, :tile_count, :page_count, :audience, :columns, :rows

      # A set with no pages is exactly what WordListDrafter already answers.
      def single_page_set
        tiles = WordListDrafter.new(
          topic: topic, columns: columns, rows: rows, audience: audience.presence,
        ).call

        { root_tiles: tiles, children: [] }
      rescue WordListDrafter::GenerationError => e
        raise GenerationError, e.message
      end

      def generate_via_openai
        client = OpenAiClient.new(
          prompt: topic,
          messages: [{ role: "user", content: build_prompt }],
        )
        client.instance_variable_set(:@model, OpenAiClient::GTP_MODEL)
        result = client.create_chat(true)

        raise GenerationError, "OpenAI returned no content" if result[:content].blank?

        result[:content]
      end

      def build_prompt
        <<~PROMPT
          You are building a set of AAC (Augmentative and Alternative Communication) boards
          for a nonspeaking communicator. The set's topic is: #{topic}
          #{audience.present? ? "It is for: #{audience}" : ""}

          The set is a main board plus exactly #{page_count} pages. Each page is opened by a
          folder tile on the main board.

          Generate EXACTLY #{tile_count} tiles for the main board AND EXACTLY #{tile_count}
          tiles for each page — every board in the set is the same fixed grid, and a partial
          last row leaves visible dead cells.

          Structure rules:
          - Give every page a "key": lowercase letters, numbers and underscores only.
          - Every page must have exactly one tile on the main board that opens it. Give that
            tile "links_to" set to the page's key. It counts towards the main board's
            #{tile_count} tiles.
          - Every page must include one tile that goes back, with "links_to" set to
            "#{Plan::ROOT_KEY}". It counts towards that page's #{tile_count} tiles.
          - No other tile has "links_to".

          Word rules:
          - Boards for talking, not vocabulary lists. Favour words that finish a sentence
            over words that name a thing.
          - The main board carries the core words the whole set leans on — pronouns, verbs,
            and words like "more", "stop", "help". Pages carry their own subject's words.
          - No near-duplicates within a board ("happy" and "glad"). Each tile costs a cell.
          - Keep each label short — 1-2 words.
          - Give every tile a part_of_speech from exactly this list:
            #{ColorHelper::PARTS_OF_SPEECH.join(", ")}
          - Classify by communicative function, not strict grammar: "more", "yes" and
            "please" are social; "no", "not" and "stop" are important_function.

          Respond in JSON format:
          {
            "root": [
              { "label": "I", "part_of_speech": "pronoun" },
              { "label": "Food", "part_of_speech": "noun", "links_to": "food" }
            ],
            "pages": [
              {
                "key": "food",
                "name": "Food",
                "tiles": [
                  { "label": "apple", "part_of_speech": "noun" },
                  { "label": "back", "part_of_speech": "social", "links_to": "#{Plan::ROOT_KEY}" }
                ]
              }
            ]
          }

          Return ONLY the JSON, no other text.
        PROMPT
      end

      def parse_response(raw)
        data = JSON.parse(raw)
        children = clean_children(Array(data["pages"]))
        child_keys = children.map { |child| child[:key] }
        root_tiles = clean_tiles(Array(data["root"]), known_keys: child_keys)

        # Only a response with nothing usable in it is an error — a short draft
        # fills the form and the counter shows the gap.
        raise GenerationError, "AI returned no usable words" if root_tiles.empty?

        { root_tiles: root_tiles, children: children }
      rescue JSON::ParserError => e
        raise GenerationError, "Failed to parse AI response: #{e.message}"
      end

      # Keys are cleaned before any tile is, because a tile's link is only kept
      # when it names a page that survived.
      def clean_children(raw_pages)
        seen = Set.new

        pages = raw_pages.filter_map do |page|
          next unless page.is_a?(Hash)

          key = normalize_key(page["key"])
          next if key.blank?
          next unless seen.add?(key)

          { key: key, name: page["name"].to_s.strip.presence || key.titleize, tiles: Array(page["tiles"]) }
        end.first(page_count)

        keys = pages.map { |page| page[:key] }
        pages.map do |page|
          page.merge(tiles: clean_tiles(page[:tiles], known_keys: keys + [Plan::ROOT_KEY]))
        end
      end

      def normalize_key(value)
        value.to_s.strip.downcase.gsub(/[^a-z0-9_]+/, "_").gsub(/\A_+|_+\z/, "")
      end

      def clean_tiles(raw_tiles, known_keys:)
        seen = Set.new

        raw_tiles.filter_map do |tile|
          next unless tile.is_a?(Hash)

          label = (tile["label"] || tile["word"]).to_s.strip
          next if label.blank?
          next unless seen.add?(label.downcase)

          {
            label: label,
            part_of_speech: part_of_speech_for(tile),
            links_to: link_for(tile, known_keys),
          }.compact
        end.first(tile_count)
      end

      def part_of_speech_for(tile)
        value = tile["part_of_speech"].to_s.strip.downcase
        ColorHelper::PARTS_OF_SPEECH.include?(value) ? value : "default"
      end

      # A link naming a page that isn't in the set would fail PlanValidator on
      # arrival, which is worse than a tile that simply doesn't open anything.
      def link_for(tile, known_keys)
        target = normalize_key(tile["links_to"])
        return nil if target.blank? || known_keys.exclude?(target)

        target
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/services/boards/admin_builder/set_drafter_spec.rb`
Expected: PASS

Note: `normalize_key("__root__")` must return `"__root__"` — the leading/trailing underscore strip would otherwise eat it. Verify this test passes:

```
it "keeps a child's link back to the root"
```

If it fails, change `normalize_key` so the `\A_+|_+\z` strip is skipped when the value already equals `Plan::ROOT_KEY`:

```ruby
      def normalize_key(value)
        cleaned = value.to_s.strip.downcase.gsub(/[^a-z0-9_]+/, "_")
        return cleaned if cleaned == Plan::ROOT_KEY

        cleaned.gsub(/\A_+|_+\z/, "")
      end
```

- [ ] **Step 5: Commit**

```bash
git add app/services/boards/admin_builder/set_drafter.rb spec/services/boards/admin_builder/set_drafter_spec.rb
git commit -m "feat(admin): draft a whole linked board set in one AI call"
```

---

### Task 3: Wire the set drafter into the form

**Files:**
- Modify: `config/routes.rb:88-98` (add `post :draft_set` to the collection block)
- Modify: `app/controllers/admin/board_builds_controller.rb` (new `draft_set` action; `submitted_form` gains `page_count`; `blank_form` gains `page_count`)
- Modify: `app/views/admin/board_builds/_form.html.erb` (page-count select + button in the Pages card)
- Test: `spec/requests/admin/board_builds_spec.rb`

**Interfaces:**
- Consumes: `Boards::AdminBuilder::SetDrafter` (Task 2), `Boards::AdminBuilder::WordList.render` (Task 1)
- Produces: `POST /admin/board_builds/draft_set` → renders `new` with `@form[:words]`, `@form[:tiles]`, `@form[:children]` populated. Route helper `draft_set_admin_dashboard_board_builds_path`.

- [ ] **Step 1: Write the failing test**

Append to the end of `spec/requests/admin/board_builds_spec.rb`, inside the outermost `RSpec.describe` block:

```ruby
  describe "POST draft_set" do
    before { sign_in admin }

    def stub_set_drafter(result)
      allow(Boards::AdminBuilder::SetDrafter).to receive(:new).and_return(
        instance_double(Boards::AdminBuilder::SetDrafter, call: result),
      )
    end

    let(:drafted) do
      {
        root_tiles: [
          { label: "I", part_of_speech: "pronoun" },
          { label: "Food", part_of_speech: "noun", links_to: "food" },
        ],
        children: [
          { key: "food", name: "Food",
            tiles: [{ label: "apple", part_of_speech: "noun" },
                    { label: "back", part_of_speech: "social", links_to: "__root__" }] },
        ],
      }
    end

    it "fills the root textarea with link tokens and renders the page block" do
      stub_set_drafter(drafted)

      post draft_set_admin_dashboard_board_builds_path,
           params: form_params(words: "", page_count: "1", columns: "1", rows: "2")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Food | noun | &gt;food")
      expect(response.body).to include("apple | noun")
      expect(response.body).to include("children[0][key]")
    end

    it "writes nothing" do
      stub_set_drafter(drafted)

      expect {
        post draft_set_admin_dashboard_board_builds_path,
             params: form_params(words: "", page_count: "1", columns: "1", rows: "2")
      }.to not_change(Board, :count).and not_change(Image, :count).and not_change(AdminBoardBuild, :count)
    end

    it "reports a generation failure without losing what was typed" do
      allow(Boards::AdminBuilder::SetDrafter).to receive(:new).and_raise(
        Boards::AdminBuilder::SetDrafter::GenerationError, "OpenAI returned no content",
      )

      post draft_set_admin_dashboard_board_builds_path,
           params: form_params(name: "Playground", page_count: "1")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Couldn&#39;t draft the set")
      expect(response.body).to include("Playground")
    end

    it "refuses to draft with nothing to work from" do
      post draft_set_admin_dashboard_board_builds_path,
           params: form_params(name: "", topic: "", words: "", page_count: "1")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("draft from")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/requests/admin/board_builds_spec.rb -e "POST draft_set"`
Expected: FAIL with `undefined local variable or method 'draft_set_admin_dashboard_board_builds_path'`

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside the `resources :board_builds ... collection do` block (currently lines 89-93), add after `post :draft`:

```ruby
        post :draft_set
```

- [ ] **Step 4: Add the controller action**

In `app/controllers/admin/board_builds_controller.rb`, add a constant beside `DEFAULT_ROWS`:

```ruby
    DEFAULT_PAGE_COUNT = 0
```

Add the action immediately after `draft`:

```ruby
    # Optional step zero, the multi-page form of `draft`. Drafts the whole set
    # — root word list with its folder tiles already linked, plus each page —
    # into the form and stops there. Nothing is previewed or built from it.
    def draft_set
      @form = submitted_form
      @form = @form.merge(suggested_context(@form)) if @form[:topic].blank? || @form[:name].blank?
      @problems = draft_problems(@form)
      return render(:new, status: :unprocessable_entity) if @problems.any?

      set = Boards::AdminBuilder::SetDrafter.new(
        topic: @form[:topic],
        columns: @form[:columns].to_i,
        rows: @form[:rows].to_i,
        page_count: @form[:page_count].to_i,
        audience: @form[:audience],
      ).call

      @form = @form.merge(
        words: tiles_to_words(set[:root_tiles]),
        tiles: set[:root_tiles],
        children: children_form_from(set[:children]),
      )
      flash.now[:notice] = draft_set_notice(set, @form)
      render :new
    rescue Boards::AdminBuilder::SetDrafter::GenerationError => e
      @problems = ["Couldn't draft the set: #{e.message}"]
      render :new, status: :unprocessable_entity
    rescue Boards::AdminBuilder::ContextSuggester::GenerationError => e
      @problems = ["Couldn't work out the topic: #{e.message}"]
      render :new, status: :unprocessable_entity
    end
```

Add these private helpers next to `tiles_to_words`:

```ruby
    # Children arrive as tile hashes; the form wants a rendered textarea per
    # page. Grids are deliberately left blank so each page inherits the root's.
    def children_form_from(children)
      Array(children).map do |child|
        {
          key: child[:key].to_s,
          name: child[:name].to_s,
          columns: "",
          rows: "",
          words: tiles_to_words(child[:tiles]),
          tiles: child[:tiles],
        }
      end
    end

    def draft_set_notice(set, form)
      wanted = form[:columns].to_i * form[:rows].to_i
      pages = set[:children].size
      short = ([set[:root_tiles]] + set[:children].map { |child| child[:tiles] })
              .count { |tiles| tiles.size != wanted }

      base = "Drafted the main board and #{pages} #{"page".pluralize(pages)}."
      return "#{base} Edit them, then preview the art." if short.zero?

      "#{base} #{short} #{"board".pluralize(short)} didn't come back with exactly #{wanted} words — " \
        "check the counts before previewing."
    end
```

- [ ] **Step 5: Carry `page_count` through the form hash**

In `blank_form`, add after `rows:`:

```ruby
        page_count: DEFAULT_PAGE_COUNT.to_s,
```

In `submitted_form`, add after `rows:`:

```ruby
        page_count: params[:page_count].to_s.strip,
```

- [ ] **Step 6: Add the control to the form view**

In `app/views/admin/board_builds/_form.html.erb`, replace the "Add a page" button (lines 122-125) with:

```erb
      <div class="flex items-center gap-2">
        <%= select_tag :page_count,
              options_for_select((0..Boards::AdminBuilder::SetDrafter::MAX_PAGES).map { |n| [n.zero? ? "no pages" : "#{n} #{"page".pluralize(n)}", n.to_s] }, @form[:page_count]),
              class: "admin-input border rounded px-2 py-1.5 text-xs focus:border-indigo-500 focus:outline-none" %>
        <%# formaction, not a second form: the drafter has to see the topic,
            audience and grid typed above. formnovalidate for the same reason
            the word-list drafter has it — a missing name is inferred. %>
        <button type="submit" id="draft-set-button" formaction="<%= draft_set_admin_dashboard_board_builds_path %>" formnovalidate
                class="text-xs font-medium px-3 py-1.5 rounded border admin-input cursor-pointer text-t1 whitespace-nowrap">
          Draft the whole set with AI
        </button>
        <button type="button" id="add-page"
                class="text-xs font-medium px-3 py-1.5 rounded border admin-input cursor-pointer text-t1 whitespace-nowrap">
          Add a page
        </button>
      </div>
```

At the end of the `<script>` block in the same file, before the closing `})();`, add the same replace-confirmation the word-list drafter has:

```js
    // Drafting the set replaces the root list AND every page.
    var draftSetButton = document.getElementById("draft-set-button");
    if (draftSetButton) {
      draftSetButton.addEventListener("click", function (event) {
        var hasPages = pages.querySelectorAll(".page-block").length > 0;
        if (words.value.trim() === "" && !hasPages) return;
        if (!window.confirm("Replace the word list and every page with an AI draft?")) {
          event.preventDefault();
        }
      });
    }
```

- [ ] **Step 7: Run the tests**

Run: `bundle exec rspec spec/requests/admin/board_builds_spec.rb`
Expected: PASS, including the pre-existing examples.

- [ ] **Step 8: Update the docs**

In `.claude-notes/board-builder.md`, in the admin Board Builder section, add a bullet:

```markdown
- **`Boards::AdminBuilder::SetDrafter` drafts a whole linked set in one call**
  — root word list with its folder tiles already carrying `links_to`, plus each
  page's key, name and words. It honours the two `PlanValidator` rules by
  construction: it states the exact per-page tile count in the prompt, and it
  never gives a child a grid of its own. Like every other AI path here it only
  fills the form. `Boards::AdminBuilder::WordList` is the single parser/renderer
  for the textarea format; `.render` is the exact inverse of `.parse`.
```

Add to `CHANGELOG.md` under an Unreleased heading (create the heading if absent):

```markdown
- Admin Board Builder can draft a whole linked board set — main board plus up to four pages — in one AI call.
```

- [ ] **Step 9: Commit**

```bash
git add config/routes.rb app/controllers/admin/board_builds_controller.rb app/views/admin/board_builds/_form.html.erb spec/requests/admin/board_builds_spec.rb .claude-notes/board-builder.md CHANGELOG.md
git commit -m "feat(admin): draft the whole board set from the builder form"
```

---

# Phase 2 — Description and tags

### Task 4: Persist description, tags and audience on a build

**Files:**
- Create: `db/migrate/<timestamp>_add_metadata_to_admin_board_builds.rb`
- Modify: `db/schema.rb` (generated)
- Modify: `app/models/admin_board_build.rb` (annotation block only, regenerated)
- Test: `spec/models/admin_board_build_spec.rb` (create if absent)

**Interfaces:**
- Produces: `AdminBoardBuild#description` (text, nullable), `#tags` (array of string, default `[]`, not null), `#audience` (string, nullable)

- [ ] **Step 1: Write the failing test**

Create or append to `spec/models/admin_board_build_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe AdminBoardBuild do
  it "defaults tags to an empty array and leaves description and audience blank" do
    build = described_class.create!(name: "Playground", columns_count: 2, rows_count: 2)

    expect(build.tags).to eq([])
    expect(build.description).to be_nil
    expect(build.audience).to be_nil
  end

  it "stores tags as an array" do
    build = described_class.create!(
      name: "Playground", columns_count: 2, rows_count: 2,
      tags: %w[playground outdoor play], description: "A board for the playground.",
      audience: "an early communicator",
    )

    expect(build.reload.tags).to eq(%w[playground outdoor play])
    expect(build.description).to eq("A board for the playground.")
    expect(build.audience).to eq("an early communicator")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/admin_board_build_spec.rb`
Expected: FAIL with `unknown attribute 'tags'`

- [ ] **Step 3: Generate and write the migration**

```bash
bin/rails generate migration AddMetadataToAdminBoardBuilds
```

Replace the generated file's body with:

```ruby
class AddMetadataToAdminBoardBuilds < ActiveRecord::Migration[8.0]
  def change
    add_column :admin_board_builds, :description, :text
    add_column :admin_board_builds, :tags, :string, array: true, default: [], null: false
    add_column :admin_board_builds, :audience, :string
  end
end
```

- [ ] **Step 4: Run the migration**

```bash
bin/rails db:migrate
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/models/admin_board_build_spec.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/admin_board_build.rb spec/models/admin_board_build_spec.rb
git commit -m "feat(admin): store description, tags and audience on a board build"
```

---

### Task 5: `Boards::AdminBuilder::MetadataSuggester`

**Files:**
- Create: `app/services/boards/admin_builder/metadata_suggester.rb`
- Test: `spec/services/boards/admin_builder/metadata_suggester_spec.rb`

**Interfaces:**
- Consumes: `Board.public_boards_tags` and `Board.normalize_tag_value` (both existing class methods)
- Produces:
  - `Boards::AdminBuilder::MetadataSuggester.new(name:, topic: nil, audience: nil, labels: [], page_names: [], vocabulary: nil).call -> { description: String, tags: Array<String> }`
  - `Boards::AdminBuilder::MetadataSuggester::GenerationError`
  - Constants `MAX_DESCRIPTION_LENGTH = 300`, `MAX_TAGS = 6`, `MAX_NEW_TAGS = 2`, `MAX_TAG_LENGTH = 30`, `VOCABULARY_SAMPLE_SIZE = 60`

- [ ] **Step 1: Write the failing test**

Create `spec/services/boards/admin_builder/metadata_suggester_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Boards::AdminBuilder::MetadataSuggester do
  def ai_metadata(description: "A board for talking at the playground.", tags: ["playground"])
    { "description" => description, "tags" => tags }.to_json
  end

  def stub_ai(content)
    allow_any_instance_of(OpenAiClient).to receive(:create_chat)
      .and_return({ role: "assistant", content: content })
  end

  before { stub_ai(ai_metadata) }

  def suggest(**overrides)
    described_class.new(
      **{ name: "At the Playground", topic: "the playground", labels: %w[swing slide run],
          vocabulary: %w[playground outdoor core] }.merge(overrides),
    ).call
  end

  describe "#call" do
    it "returns a description and tags" do
      expect(suggest).to eq({ description: "A board for talking at the playground.", tags: ["playground"] })
    end

    it "refuses to run with nothing to describe" do
      expect { described_class.new(name: "", topic: "", labels: [], vocabulary: []).call }
        .to raise_error(described_class::GenerationError, /name, a topic, or some words/)
    end
  end

  describe "cleanup of the description" do
    it "strips HTML, because three of four frontend surfaces render it as plain text" do
      stub_ai(ai_metadata(description: "<h2>Purpose</h2><p>A playground board.</p>"))

      expect(suggest[:description]).to eq("Purpose A playground board.")
    end

    it "truncates a runaway description" do
      stub_ai(ai_metadata(description: "word " * 200))

      expect(suggest[:description].length).to be <= described_class::MAX_DESCRIPTION_LENGTH
    end
  end

  describe "cleanup of the tags" do
    it "normalizes casing and whitespace" do
      stub_ai(ai_metadata(tags: ["  PlayGround  ", "Outdoor   Play"]))

      expect(suggest(vocabulary: ["playground", "outdoor play"])[:tags]).to eq(["playground", "outdoor play"])
    end

    it "keeps at most two tags that aren't already in the vocabulary" do
      stub_ai(ai_metadata(tags: %w[playground new_one new_two new_three]))

      expect(suggest(vocabulary: %w[playground])[:tags]).to eq(%w[playground new_one new_two])
    end

    it "keeps more than two tags when they all come from the vocabulary" do
      stub_ai(ai_metadata(tags: %w[playground outdoor core]))

      expect(suggest(vocabulary: %w[playground outdoor core])[:tags]).to eq(%w[playground outdoor core])
    end

    it "caps the total" do
      stub_ai(ai_metadata(tags: %w[a b c d e f g h]))

      expect(suggest(vocabulary: %w[a b c d e f g h])[:tags].size).to eq(described_class::MAX_TAGS)
    end

    it "drops a tag longer than the cap and blank entries" do
      stub_ai(ai_metadata(tags: ["playground", "x" * 40, "  ", nil]))

      expect(suggest(vocabulary: %w[playground])[:tags]).to eq(%w[playground])
    end

    it "drops a repeated tag" do
      stub_ai(ai_metadata(tags: %w[playground Playground]))

      expect(suggest(vocabulary: %w[playground])[:tags]).to eq(%w[playground])
    end

    it "reads the live public vocabulary when none is passed" do
      allow(Board).to receive(:public_boards_tags).and_return(%w[zebra apple])
      stub_ai(ai_metadata(tags: %w[apple]))

      expect(suggest(vocabulary: nil)[:tags]).to eq(%w[apple])
      expect(Board).to have_received(:public_boards_tags)
    end
  end

  describe "failures" do
    it "raises when OpenAI returns nothing" do
      stub_ai("")
      expect { suggest }.to raise_error(described_class::GenerationError, /no content/)
    end

    it "raises on unparseable JSON" do
      stub_ai("not json")
      expect { suggest }.to raise_error(described_class::GenerationError, /Failed to parse/)
    end

    it "raises when neither a description nor a tag came back" do
      stub_ai(ai_metadata(description: "  ", tags: []))
      expect { suggest }.to raise_error(described_class::GenerationError, /nothing usable/)
    end
  end

  describe "the prompt" do
    def prompt_for(**args)
      captured = nil
      allow(OpenAiClient).to receive(:new) do |opts|
        captured = opts[:messages].first[:content]
        instance_double(OpenAiClient, create_chat: { role: "assistant", content: ai_metadata })
          .tap { |double| allow(double).to receive(:instance_variable_set) }
      end
      described_class.new(**{ name: "At the Playground", topic: "the playground",
                              labels: %w[swing slide], vocabulary: %w[zebra apple] }.merge(args)).call
      captured
    end

    it "hands the model the vocabulary, sorted" do
      expect(prompt_for).to include("apple, zebra")
    end

    it "sorts and truncates a large vocabulary deterministically" do
      big = (1..100).map { |n| format("tag%03d", n) }

      prompt = prompt_for(vocabulary: big.shuffle)
      expect(prompt).to include("tag001")
      expect(prompt).not_to include("tag061")
    end

    it "asks for plain text and no word list" do
      expect(prompt_for).to include("Plain text")
      expect(prompt_for).to include("Do not list the words")
    end

    it "states both tag limits" do
      expect(prompt_for).to include("at most #{described_class::MAX_TAGS}")
      expect(prompt_for).to include("at most #{described_class::MAX_NEW_TAGS}")
    end

    it "includes the audience and page names only when given" do
      expect(prompt_for(audience: "a preschooler")).to include("It is for: a preschooler")
      expect(prompt_for(page_names: ["Food"])).to include("Food")
      expect(prompt_for).not_to include("It is for:")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/boards/admin_builder/metadata_suggester_spec.rb`
Expected: FAIL with `uninitialized constant Boards::AdminBuilder::MetadataSuggester`

- [ ] **Step 3: Write the service**

Create `app/services/boards/admin_builder/metadata_suggester.rb`:

```ruby
module Boards
  module AdminBuilder
    # Suggests a board's public description and tags from whatever the form
    # currently holds. One OpenAI call returning `{ description:, tags: }`.
    #
    # Deliberately a separate action from drafting rather than part of it: the
    # admin edits the word list after a draft, so a description generated from
    # the pre-edit list would be stale on arrival.
    #
    # Two constraints come from outside this class and must not be relaxed here:
    #
    #   * **The description is plain text.** `board.description` is rendered as
    #     text on three of four frontend surfaces and as HTML on one, so an HTML
    #     answer shows up as literal tags for most readers.
    #   * **Tags feed the public catalogue's filter.** `Board.public_boards_tags`
    #     is what the frontend offers as filter chips, so an unconstrained
    #     suggester fragments it ("playground", "the playground", "outdoor
    #     play"). The live vocabulary goes into the prompt as the preferred set
    #     and genuinely new tags are rationed.
    #
    # ONLY EVER POPULATES THE FORM. No credit charge: admin-owned boards.
    class MetadataSuggester
      class GenerationError < StandardError; end

      MAX_DESCRIPTION_LENGTH = 300
      MAX_TAGS = 6
      MAX_NEW_TAGS = 2
      MAX_TAG_LENGTH = 30
      # Bounds the prompt. Sorted before truncating so the same vocabulary
      # always produces the same prompt.
      VOCABULARY_SAMPLE_SIZE = 60
      # Enough of the board to describe it without paying for 84 tiles.
      LABEL_SAMPLE_SIZE = 40

      def initialize(name:, topic: nil, audience: nil, labels: [], page_names: [], vocabulary: nil)
        @name = name.to_s.strip
        @topic = topic.to_s.strip
        @audience = audience.to_s.strip
        @labels = Array(labels).map { |label| label.to_s.strip }.reject(&:blank?).first(LABEL_SAMPLE_SIZE)
        @page_names = Array(page_names).map { |page| page.to_s.strip }.reject(&:blank?)
        @vocabulary = clean_vocabulary(vocabulary)
      end

      def call
        if name.blank? && topic.blank? && labels.empty?
          raise GenerationError, "give the board a name, a topic, or some words to work from"
        end

        parse_response(generate_via_openai)
      end

      private

      attr_reader :name, :topic, :audience, :labels, :page_names, :vocabulary

      def clean_vocabulary(supplied)
        values = supplied.nil? ? Board.public_boards_tags : supplied

        Array(values)
          .map { |tag| Board.normalize_tag_value(tag) }
          .reject(&:blank?)
          .uniq
          .sort
          .first(VOCABULARY_SAMPLE_SIZE)
      end

      def generate_via_openai
        client = OpenAiClient.new(
          prompt: name.presence || topic.presence || labels.first.to_s,
          messages: [{ role: "user", content: build_prompt }],
        )
        client.instance_variable_set(:@model, OpenAiClient::GTP_MODEL)
        result = client.create_chat(true)

        raise GenerationError, "OpenAI returned no content" if result[:content].blank?

        result[:content]
      end

      def build_prompt
        <<~PROMPT
          You are cataloguing an AAC (Augmentative and Alternative Communication) board so
          teachers and parents can find it in a public library of boards.

          #{name.present? ? "The board is called: #{name}" : "The board has no name."}
          #{topic.present? ? "It is about: #{topic}" : ""}
          #{audience.present? ? "It is for: #{audience}" : ""}
          #{page_names.any? ? "It has these pages: #{page_names.join(", ")}" : ""}
          #{labels.any? ? "Words on it: #{labels.join(", ")}" : ""}

          Write two things.

          "description" — one or two sentences saying what the board is for and who would
          use it. Plain text only: no HTML, no markdown, no headings, no bullet points.
          At most #{MAX_DESCRIPTION_LENGTH} characters. Do not list the words on the board.

          "tags" — short lowercase keywords for filtering a board library. Reuse these
          existing tags wherever one fits, rather than inventing a near-synonym:
          #{vocabulary.any? ? vocabulary.join(", ") : "(the library has no tags yet)"}
          Return at most #{MAX_TAGS} tags in total, of which at most #{MAX_NEW_TAGS} may be
          new tags that aren't in the list above. One to three words each, lowercase.

          Respond in JSON format:
          { "description": "A board for talking at the playground.", "tags": ["playground", "outdoor play"] }

          Return ONLY the JSON, no other text.
        PROMPT
      end

      def parse_response(raw)
        data = JSON.parse(raw)
        description = clean_description(data["description"])
        tags = clean_tags(Array(data["tags"]))

        raise GenerationError, "AI returned nothing usable" if description.blank? && tags.empty?

        { description: description, tags: tags }
      rescue JSON::ParserError => e
        raise GenerationError, "Failed to parse AI response: #{e.message}"
      end

      # Models answer a "plain text" request with markup often enough to be
      # worth stripping rather than trusting.
      def clean_description(value)
        value.to_s.gsub(/<[^>]*>/, " ").squish.truncate(MAX_DESCRIPTION_LENGTH)
      end

      # Order is the model's, so its best guess survives the cap. New tags are
      # rationed rather than forbidden — a genuinely new subject deserves one.
      def clean_tags(raw_tags)
        known = vocabulary.to_set
        seen = Set.new
        new_count = 0

        raw_tags.filter_map do |raw|
          tag = Board.normalize_tag_value(raw)
          next if tag.blank? || tag.length > MAX_TAG_LENGTH
          next unless seen.add?(tag)

          unless known.include?(tag)
            next if new_count >= MAX_NEW_TAGS

            new_count += 1
          end

          tag
        end.first(MAX_TAGS)
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/services/boards/admin_builder/metadata_suggester_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/services/boards/admin_builder/metadata_suggester.rb spec/services/boards/admin_builder/metadata_suggester_spec.rb
git commit -m "feat(admin): suggest a board description and catalogue tags"
```

---

### Task 6: Description and tags in the form, and on the built board

**Files:**
- Modify: `config/routes.rb` (add `post :describe` to the `board_builds` collection block)
- Modify: `app/controllers/admin/board_builds_controller.rb` (new `describe_board` action; `blank_form` / `submitted_form` gain `description` and `tags`; `create` persists the three new columns)
- Modify: `app/views/admin/board_builds/_form.html.erb` (description textarea, tags field, suggest button)
- Modify: `app/services/boards/admin_builder/build.rb:92-129` (`new_board` applies description and tags to the root)
- Test: `spec/requests/admin/board_builds_spec.rb`, `spec/services/boards/admin_builder/build_spec.rb`

**Interfaces:**
- Consumes: `Boards::AdminBuilder::MetadataSuggester` (Task 5), the columns from Task 4
- Produces:
  - `POST /admin/board_builds/describe` → renders `new` with `@form[:description]` and `@form[:tags]` filled. Route helper `describe_admin_dashboard_board_builds_path`.
  - `@form[:tags]` is a **comma-separated String** in the form; the controller splits it.
  - `Admin::BoardBuildsController#submitted_tags -> Array<String>` (private, normalized)

**Note on naming:** the action is routed as `describe` but the Ruby method must be `describe_board` — `describe` collides with nothing in Rails but reads badly next to RSpec in this codebase, and an explicit `to:` keeps the URL clean.

- [ ] **Step 1: Write the failing test**

Append to `spec/requests/admin/board_builds_spec.rb`:

```ruby
  describe "POST describe" do
    before { sign_in admin }

    def stub_suggester(result)
      allow(Boards::AdminBuilder::MetadataSuggester).to receive(:new).and_return(
        instance_double(Boards::AdminBuilder::MetadataSuggester, call: result),
      )
    end

    it "fills the description and tags fields" do
      stub_suggester({ description: "A board for the playground.", tags: %w[playground outdoor] })

      post describe_admin_dashboard_board_builds_path, params: form_params

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("A board for the playground.")
      expect(response.body).to include("playground, outdoor")
    end

    it "writes nothing" do
      stub_suggester({ description: "A board.", tags: %w[playground] })

      expect { post describe_admin_dashboard_board_builds_path, params: form_params }
        .to not_change(Board, :count).and not_change(AdminBoardBuild, :count)
    end

    it "reports a generation failure without losing what was typed" do
      allow(Boards::AdminBuilder::MetadataSuggester).to receive(:new).and_raise(
        Boards::AdminBuilder::MetadataSuggester::GenerationError, "OpenAI returned no content",
      )

      post describe_admin_dashboard_board_builds_path, params: form_params(name: "Playground")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Couldn&#39;t suggest a description")
      expect(response.body).to include("Playground")
    end
  end

  describe "POST create with metadata" do
    before { sign_in admin }

    it "stores the description, normalized tags and audience on the build" do
      post admin_dashboard_board_builds_path, params: form_params(
        description: "  A board for the playground.  ",
        tags: " PlayGround , Outdoor   Play ,, playground ",
        audience: "an early communicator",
      )

      build = AdminBoardBuild.last
      expect(build.description).to eq("A board for the playground.")
      expect(build.tags).to eq(["playground", "outdoor play"])
      expect(build.audience).to eq("an early communicator")
    end
  end
```

Append to `spec/services/boards/admin_builder/build_spec.rb`, inside the outermost describe:

```ruby
  describe "description and tags" do
    it "applies them to the root board only" do
      build = AdminBoardBuild.create!(
        name: "Playground",
        columns_count: 1,
        rows_count: 1,
        description: "A board for the playground.",
        tags: %w[playground outdoor],
        plan: {
          "tiles" => [{ "label" => "Food", "part_of_speech" => "noun", "links_to" => "food" }],
          "children" => [{ "key" => "food", "name" => "Food",
                           "tiles" => [{ "label" => "apple", "part_of_speech" => "noun" }] }],
        },
      )

      root = described_class.new(admin_board_build: build).call
      child = build.reload.set_boards.last

      expect(root.description).to eq("A board for the playground.")
      expect(root.tags).to eq(%w[playground outdoor])
      expect(child.id).not_to eq(root.id)
      expect(child.description).to be_blank
      expect(child.tags).to eq([])
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/requests/admin/board_builds_spec.rb -e "POST describe" spec/services/boards/admin_builder/build_spec.rb -e "description and tags"`
Expected: FAIL — undefined route helper, and description nil on the root board.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, in the `board_builds` collection block, after `post :draft_set`:

```ruby
        post :describe, to: "board_builds#describe_board"
```

- [ ] **Step 4: Add the controller action**

In `app/controllers/admin/board_builds_controller.rb`, after `suggest`:

```ruby
    # Fills the public description and catalogue tags from whatever the form
    # currently holds. Separate from drafting on purpose — the word list is
    # usually edited after a draft, and a description written from the pre-edit
    # list would be stale.
    def describe_board
      @form = submitted_form
      pages = pages_for(@form)

      metadata = Boards::AdminBuilder::MetadataSuggester.new(
        name: @form[:name],
        topic: @form[:topic],
        audience: @form[:audience],
        labels: Boards::AdminBuilder::Plan.labels(pages),
        page_names: pages.drop(1).map { |page| page[:name] },
      ).call

      @form = @form.merge(description: metadata[:description], tags: metadata[:tags].join(", "))
      flash.now[:notice] = "Suggested a description and tags — edit them before you build."
      render :new
    rescue Boards::AdminBuilder::MetadataSuggester::GenerationError => e
      @problems = ["Couldn't suggest a description: #{e.message}"]
      render :new, status: :unprocessable_entity
    end
```

- [ ] **Step 5: Carry the fields through the form hash and into `create`**

In `blank_form`, add:

```ruby
        description: "",
        tags: "",
```

In `submitted_form`, add:

```ruby
        description: params[:description].to_s.strip,
        tags: params[:tags].to_s,
```

Add a private helper beside `checked?`:

```ruby
    # The form carries tags as one comma-separated string (the shape
    # Admin::VideoBoardsController uses). Normalized here so nothing downstream
    # has to care how they were typed. Takes the raw string rather than the
    # form hash because Task 7's `update` reads them straight off params.
    def submitted_tags(tags:)
      tags.to_s.split(",").map { |tag| Board.normalize_tag_value(tag) }.reject(&:blank?).uniq
    end
```

In `create`, add to the `AdminBoardBuild.create!` hash, after `topic:`:

```ruby
        description: @form[:description].presence,
        tags: submitted_tags(tags: @form[:tags]),
        audience: @form[:audience].presence,
```

- [ ] **Step 6: Apply them to the root board at build time**

In `app/services/boards/admin_builder/build.rb`, inside `new_board`, add to the `Board.new(...)` argument list after `settings: settings_for(page),`:

```ruby
          # Catalogue metadata belongs to the root alone: child pages are
          # created with `predefined: false` and never appear in
          # `Board.public_boards`, so tagging them would fill the public tag
          # filter with folder-page noise.
          description: root ? build.description : nil,
          tags: root ? Array(build.tags) : [],
```

- [ ] **Step 7: Add the fields to the form view**

In `app/views/admin/board_builds/_form.html.erb`, insert a new card immediately after the closing `</div>` of the first `admin-card` block (currently line 59):

```erb
  <div class="admin-card border rounded-xl p-5 mb-6">
    <div class="flex items-start justify-between gap-4 mb-3">
      <div>
        <h2 class="text-sm font-medium text-t1">Catalogue listing <span class="text-t3 font-normal">(optional)</span></h2>
        <p class="text-[11px] text-t3 mt-0.5">
          How the board reads in the public library. Tags are what the filter chips are built from —
          reuse an existing one wherever it fits.
        </p>
      </div>
      <%# formaction, not a second form: the suggestion is worked out from the
          words and pages typed in this same form. %>
      <button type="submit" formaction="<%= describe_admin_dashboard_board_builds_path %>" formnovalidate
              class="text-xs font-medium px-3 py-1.5 rounded border admin-input cursor-pointer text-t1 whitespace-nowrap">
        Suggest description &amp; tags
      </button>
    </div>

    <div class="flex flex-col gap-4">
      <div>
        <label class="block text-xs font-medium text-t2 mb-1" for="description">Description</label>
        <%= text_area_tag :description, @form[:description], id: "description", rows: 3,
              placeholder: "A board for talking at the playground.",
              class: "admin-input border rounded px-3 py-2 text-sm w-full focus:border-indigo-500 focus:outline-none" %>
        <p class="text-[11px] text-t3 mt-1">Plain text — no HTML. Most places render it as text, so tags would show up literally.</p>
      </div>
      <div>
        <label class="block text-xs font-medium text-t2 mb-1" for="tags">Tags</label>
        <%= text_field_tag :tags, @form[:tags], id: "tags", placeholder: "playground, outdoor play",
              class: "admin-input border rounded px-3 py-2 text-sm w-full focus:border-indigo-500 focus:outline-none" %>
        <p class="text-[11px] text-t3 mt-1">Comma separated. Lowercased on save. Applied to the main board only.</p>
      </div>
    </div>
  </div>
```

Also update the audience hint at line 36, which currently claims the audience isn't saved:

```erb
        <p class="text-[11px] text-t3 mt-1">Steers the AI draft and the suggested description. Saved on the build, not on the board.</p>
```

- [ ] **Step 8: Run the tests**

Run: `bundle exec rspec spec/requests/admin/board_builds_spec.rb spec/services/boards/admin_builder/build_spec.rb`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add config/routes.rb app/controllers/admin/board_builds_controller.rb app/views/admin/board_builds/_form.html.erb app/services/boards/admin_builder/build.rb spec/requests/admin/board_builds_spec.rb spec/services/boards/admin_builder/build_spec.rb
git commit -m "feat(admin): AI-suggested description and tags on the board builder"
```

---

### Task 7: Edit description and tags after a build

**Files:**
- Modify: `config/routes.rb` (add `:update` to the `board_builds` `only:` list)
- Modify: `app/controllers/admin/board_builds_controller.rb` (`update` action; add `:update` to the `set_build` `before_action`)
- Modify: `app/views/admin/board_builds/show.html.erb` (inline form)
- Test: `spec/requests/admin/board_builds_spec.rb`

**Interfaces:**
- Consumes: `submitted_tags` (Task 6), `builder_board_for` (existing private method)
- Produces: `PATCH /admin/board_builds/:id` → redirects to `show`. Route helper `admin_dashboard_board_build_path(build)` with `method: :patch`.

- [ ] **Step 1: Write the failing test**

Append to `spec/requests/admin/board_builds_spec.rb`:

```ruby
  describe "PATCH update" do
    before { sign_in admin }

    it "updates the description and tags on the build and its root board" do
      board = built_board
      build = create_build(board: board, status: "complete")

      patch admin_dashboard_board_build_path(build),
            params: { description: "  A playground board.  ", tags: " PlayGround , outdoor play " }

      expect(response).to redirect_to(admin_dashboard_board_build_path(build))
      expect(build.reload.description).to eq("A playground board.")
      expect(build.tags).to eq(["playground", "outdoor play"])
      expect(board.reload.description).to eq("A playground board.")
      expect(board.tags).to eq(["playground", "outdoor play"])
    end

    it "clears both when submitted empty" do
      board = built_board
      board.update!(description: "old", tags: %w[old])
      build = create_build(board: board, status: "complete", description: "old", tags: %w[old])

      patch admin_dashboard_board_build_path(build), params: { description: "", tags: "" }

      expect(build.reload.description).to be_nil
      expect(build.tags).to eq([])
      expect(board.reload.description).to be_blank
      expect(board.tags).to eq([])
    end

    # The word list is immutable from here — fixing words is delete-and-rebuild.
    it "ignores anything other than description and tags" do
      board = built_board(name: "Built Board")
      build = create_build(board: board, status: "complete")

      patch admin_dashboard_board_build_path(build),
            params: { description: "New.", tags: "", name: "Hijacked", words: "nope | noun" }

      expect(build.reload.name).to eq("Playground")
      expect(board.reload.name).to eq("Built Board")
    end

    it "cannot reach a board this page didn't create" do
      other = Board.create!(name: "Someone Else's", slug: "someone-elses", user: seed_admin)
      build = create_build(board: other, status: "complete")

      patch admin_dashboard_board_build_path(build), params: { description: "Hijacked.", tags: "" }

      expect(other.reload.description).to be_blank
      expect(build.reload.description).to eq("Hijacked.")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/requests/admin/board_builds_spec.rb -e "PATCH update"`
Expected: FAIL — `No route matches [PATCH]`

- [ ] **Step 3: Add the route**

In `config/routes.rb`, change the `board_builds` resource line to include `:update`:

```ruby
    resources :board_builds, only: [:index, :new, :create, :show, :update, :destroy], as: :dashboard_board_builds do
```

- [ ] **Step 4: Add the controller action**

In `app/controllers/admin/board_builds_controller.rb`, extend the `before_action`:

```ruby
    before_action :set_build, only: %i[show update destroy publish unpublish]
```

Add the action after `show`:

```ruby
    # The only mutable part of a finished build. The word list stays frozen —
    # fixing words is still delete-and-rebuild — but a description or a tag is
    # exactly the kind of thing that is wrong once and cheap to correct.
    def update
      description = params[:description].to_s.strip.presence
      tags = submitted_tags(tags: params[:tags])

      @build.update!(description: description, tags: tags)
      builder_board_for(@build)&.update!(description: description, tags: tags)

      redirect_to admin_dashboard_board_build_path(@build), notice: "Updated the description and tags."
    end
```

`submitted_tags` is already defined with this signature in Task 6 — reuse it, don't redefine it.

- [ ] **Step 5: Add the form to the show view**

In `app/views/admin/board_builds/show.html.erb`, insert immediately after the status card's closing `</div>` (currently line 76):

```erb
<div class="admin-card border rounded-xl p-5 mb-6">
  <h2 class="text-sm font-medium text-t1 mb-1">Catalogue listing</h2>
  <p class="text-[11px] text-t3 mb-3">
    Applied to the main board. The word list can't be edited from here — that's still delete and rebuild.
  </p>
  <%= form_tag admin_dashboard_board_build_path(@build), method: :patch, data: { turbo: false } do %>
    <div class="flex flex-col gap-3">
      <div>
        <label class="block text-xs font-medium text-t2 mb-1" for="build_description">Description</label>
        <%= text_area_tag :description, @build.description, id: "build_description", rows: 3,
              class: "admin-input border rounded px-3 py-2 text-sm w-full focus:border-indigo-500 focus:outline-none" %>
      </div>
      <div>
        <label class="block text-xs font-medium text-t2 mb-1" for="build_tags">Tags</label>
        <%= text_field_tag :tags, @build.tags.join(", "), id: "build_tags",
              class: "admin-input border rounded px-3 py-2 text-sm w-full focus:border-indigo-500 focus:outline-none" %>
      </div>
      <div>
        <%= submit_tag "Save listing",
              class: "text-xs font-medium px-4 py-2 rounded border admin-input cursor-pointer text-t1" %>
      </div>
    </div>
  <% end %>
</div>
```

- [ ] **Step 6: Run the tests**

Run: `bundle exec rspec spec/requests/admin/board_builds_spec.rb`
Expected: PASS

- [ ] **Step 7: Update the docs**

In `.claude-notes/board-builder.md`, add to the admin Board Builder section:

```markdown
- **`Boards::AdminBuilder::MetadataSuggester` fills the catalogue listing** —
  a plain-text description (`boards.description` renders as text on three of
  four frontend surfaces, so HTML would show up literally) and tags steered by
  the live `Board.public_boards_tags`, rationing genuinely new tags so the
  public filter chips don't fragment. **Description and tags are applied to the
  ROOT board only** — child pages are `predefined: false` and never enter
  `Board.public_boards`. `PATCH /admin/board_builds/:id` can fix both after a
  build; nothing else about a finished build is editable.
```

Add to `CHANGELOG.md`:

```markdown
- Admin Board Builder suggests a public description and catalogue tags, and both can be corrected after a build.
```

- [ ] **Step 8: Commit**

```bash
git add config/routes.rb app/controllers/admin/board_builds_controller.rb app/views/admin/board_builds/show.html.erb spec/requests/admin/board_builds_spec.rb .claude-notes/board-builder.md CHANGELOG.md
git commit -m "feat(admin): edit a built board's description and tags"
```

---

# Phase 3 — Iteration and repair on the build page

### Task 8: Duplicate a build back into the form

**Files:**
- Modify: `config/routes.rb` (add `get :duplicate` to the `board_builds` member block)
- Modify: `app/controllers/admin/board_builds_controller.rb` (`duplicate` action + `form_from_build`)
- Modify: `app/views/admin/board_builds/show.html.erb` and `index.html.erb` (link)
- Test: `spec/requests/admin/board_builds_spec.rb`

**Interfaces:**
- Consumes: `Boards::AdminBuilder::WordList.render` (Task 1), `AdminBoardBuild#pages` (existing), the columns from Task 4
- Produces: `GET /admin/board_builds/:id/duplicate` → renders `new`. Route helper `duplicate_admin_dashboard_board_build_path(build)`.

- [ ] **Step 1: Write the failing test**

Append to `spec/requests/admin/board_builds_spec.rb`:

```ruby
  describe "GET duplicate" do
    before { sign_in admin }

    it "rehydrates the form from a stored plan, links and tile text intact" do
      build = create_build(
        topic: "the playground",
        audience: "an early communicator",
        description: "A playground board.",
        tags: %w[playground outdoor],
        plan: {
          "tiles" => [
            { "label" => "I", "part_of_speech" => "pronoun" },
            { "label" => "Food", "part_of_speech" => "noun", "display_label" => "Snacks", "links_to" => "food" },
          ],
          "children" => [
            { "key" => "food", "name" => "Food",
              "tiles" => [{ "label" => "back", "part_of_speech" => "social", "links_to" => "__root__" }] },
          ],
        },
      )

      get duplicate_admin_dashboard_board_build_path(build)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Food | noun | Snacks | &gt;food")
      expect(response.body).to include("back | social | &gt;__root__")
      expect(response.body).to include("the playground")
      expect(response.body).to include("an early communicator")
      expect(response.body).to include("A playground board.")
      expect(response.body).to include("playground, outdoor")
      expect(response.body).to include("children[0][key]")
    end

    it "writes nothing" do
      build = create_build

      expect { get duplicate_admin_dashboard_board_build_path(build) }
        .to not_change(AdminBoardBuild, :count).and not_change(Board, :count)
    end

    # Child pages inherit the root grid; copying a blank grid keeps it that way.
    it "leaves a child's grid blank" do
      build = create_build(
        plan: { "tiles" => [{ "label" => "I", "part_of_speech" => "pronoun" }],
                "children" => [{ "key" => "food", "name" => "Food",
                                 "tiles" => [{ "label" => "apple", "part_of_speech" => "noun" }] }] },
      )

      get duplicate_admin_dashboard_board_build_path(build)

      expect(response.body).to include('name="children[0][columns]" value=""')
    end

    it "redirects when the build is gone" do
      get duplicate_admin_dashboard_board_build_path(id: 0)

      expect(response).to redirect_to(admin_dashboard_board_builds_path)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/requests/admin/board_builds_spec.rb -e "GET duplicate"`
Expected: FAIL — undefined route helper.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, in the `board_builds` member block:

```ruby
        get :duplicate
```

- [ ] **Step 4: Add the controller action**

Extend the `before_action`:

```ruby
    before_action :set_build, only: %i[show update destroy publish unpublish duplicate]
```

Add the action after `show`:

```ruby
    # Loads a past build back into the authoring form. Writes nothing — it is
    # `new` with the fields filled in, so a revision is a tweak instead of a
    # re-type. The name is copied verbatim; `preview` warns about the
    # collision rather than forcing an edit up front.
    def duplicate
      @form = form_from_build(@build)
      flash.now[:notice] = "Loaded “#{@build.name}” into the form. Nothing is written until you build."
      render :new
    end
```

Add the private helper beside `blank_form`:

```ruby
    def form_from_build(build)
      pages = build.pages
      root = pages.first

      blank_form.merge(
        name: build.name.to_s,
        topic: build.topic.to_s,
        audience: build.audience.to_s,
        description: build.description.to_s,
        tags: Array(build.tags).join(", "),
        voice: build.voice.presence || DEFAULT_VOICE,
        columns: build.columns_count.to_s,
        rows: build.rows_count.to_s,
        words: tiles_to_words(root[:tiles]),
        tiles: root[:tiles],
        # Grids are left blank so every page keeps inheriting the root's, which
        # is what the stored plan meant when it omitted them.
        children: pages.drop(1).map do |page|
          {
            key: page[:key], name: page[:name], columns: "", rows: "",
            words: tiles_to_words(page[:tiles]), tiles: page[:tiles],
          }
        end,
        commercial_safe_only: build.commercial_safe_only,
      )
    end
```

- [ ] **Step 5: Add the links**

In `app/views/admin/board_builds/show.html.erb`, add inside the action button group (after the Delete button, before the closing `</div>` at line 74):

```erb
      <%= link_to "Duplicate", duplicate_admin_dashboard_board_build_path(@build),
            class: "text-xs font-medium px-3 py-2 rounded border admin-input cursor-pointer text-t1" %>
```

In `app/views/admin/board_builds/index.html.erb`, replace the action cell (lines 57-60) with:

```erb
          <td class="px-5 py-3 whitespace-nowrap">
            <%= link_to "Open", admin_dashboard_board_build_path(build),
                  class: "text-xs font-medium px-3 py-1.5 rounded border admin-input text-t1" %>
            <%= link_to "Duplicate", duplicate_admin_dashboard_board_build_path(build),
                  class: "text-xs font-medium px-3 py-1.5 rounded border admin-input text-t1 ml-1" %>
          </td>
```

- [ ] **Step 6: Run the tests**

Run: `bundle exec rspec spec/requests/admin/board_builds_spec.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/admin/board_builds_controller.rb app/views/admin/board_builds spec/requests/admin/board_builds_spec.rb
git commit -m "feat(admin): duplicate a past board build back into the form"
```

---

### Task 9: Warn about a duplicate board name at preview

**Files:**
- Modify: `app/controllers/admin/board_builds_controller.rb` (`preview` sets `@name_matches`)
- Modify: `app/views/admin/board_builds/preview.html.erb` (banner)
- Test: `spec/requests/admin/board_builds_spec.rb`

**Interfaces:**
- Consumes: `AdminBoardBuild.builder_boards` (existing), `Board.public_boards` (existing)
- Produces: `@name_matches` — an `ActiveRecord::Relation` of at most 5 `Board` records, available to `preview.html.erb`.

- [ ] **Step 1: Write the failing test**

Append to `spec/requests/admin/board_builds_spec.rb`:

```ruby
  describe "POST preview duplicate-name warning" do
    before { sign_in admin }

    it "warns about an existing public board with the same name, ignoring case" do
      Board.create!(name: "playground", slug: "playground-public", user: seed_admin, predefined: true, published: true)

      post preview_admin_dashboard_board_builds_path, params: form_params(name: "Playground")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("already a board called")
    end

    # An unpublished board built here last week is exactly the collision worth
    # catching, and it isn't in public_boards yet.
    it "warns about an unpublished board this page built" do
      built_board(name: "Playground")

      post preview_admin_dashboard_board_builds_path, params: form_params(name: "Playground")

      expect(response.body).to include("already a board called")
    end

    it "says nothing when the name is free" do
      post preview_admin_dashboard_board_builds_path, params: form_params(name: "Something Else Entirely")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("already a board called")
    end

    it "warns without blocking the build" do
      built_board(name: "Playground")

      expect { post admin_dashboard_board_builds_path, params: form_params(name: "Playground") }
        .to change(AdminBoardBuild, :count).by(1)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/requests/admin/board_builds_spec.rb -e "duplicate-name warning"`
Expected: FAIL — the warning text is absent.

- [ ] **Step 3: Set the matches in `preview`**

In `app/controllers/admin/board_builds_controller.rb`, in `preview`, after the `@preview = ...` assignment:

```ruby
      @name_matches = duplicate_name_matches(@form[:name])
```

Add the private helper:

```ruby
    # Advisory only. Two boards with one name is sometimes right; shipping it
    # by accident is what's worth catching. Both scopes are searched because a
    # board built here last week and still awaiting review isn't public yet.
    def duplicate_name_matches(name)
      return Board.none if name.blank?

      Board.where(id: Board.public_boards.select(:id))
           .or(Board.where(id: AdminBoardBuild.builder_boards.select(:id)))
           .where("lower(boards.name) = ?", name.strip.downcase)
           .limit(5)
    end
```

- [ ] **Step 4: Add the banner**

In `app/views/admin/board_builds/preview.html.erb`, insert after the header block (after line 12):

```erb
<% if @name_matches.any? %>
  <div class="admin-card border border-amber-500/40 rounded-xl p-4 mb-6">
    <p class="text-xs text-amber-400 font-medium">
      There's already a board called “<%= @form[:name] %>”.
    </p>
    <ul class="text-[11px] text-t2 mt-2 flex flex-col gap-1">
      <% @name_matches.each do |match| %>
        <li>
          <span class="font-mono">#<%= match.id %></span> ·
          <span class="font-mono"><%= match.slug %></span> ·
          <%= match.published? ? "published" : "unpublished" %>
        </li>
      <% end %>
    </ul>
    <p class="text-[11px] text-t3 mt-2">Not a blocker — rename it above if this isn't a deliberate second board.</p>
  </div>
<% end %>
```

- [ ] **Step 5: Run the tests**

Run: `bundle exec rspec spec/requests/admin/board_builds_spec.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/controllers/admin/board_builds_controller.rb app/views/admin/board_builds/preview.html.erb spec/requests/admin/board_builds_spec.rb
git commit -m "feat(admin): warn at preview when a board name is already taken"
```

---

### Task 10: Re-queue missing art

**Files:**
- Create: `app/services/boards/admin_builder/art_queue.rb`
- Modify: `app/services/boards/admin_builder/build.rb` (delete `GENERATE_BATCH_SIZE` at 26, `queue_missing_art!` at 236-243, `seed_art_prompts!` at 249-255, `art_intent_for` at 257-262; call `ArtQueue` instead)
- Modify: `config/routes.rb` (add `post :regenerate_art` to the member block)
- Modify: `app/controllers/admin/board_builds_controller.rb` (`regenerate_art` action)
- Modify: `app/views/admin/board_builds/show.html.erb` (button in the Art coverage card)
- Test: `spec/services/boards/admin_builder/art_queue_spec.rb`, `spec/requests/admin/board_builds_spec.rb`

**Interfaces:**
- Consumes: `GenerateImagesJob.perform_async(image_ids, board_id)` (existing)
- Produces:
  - `Boards::AdminBuilder::ArtQueue.call(board:, image_ids:, topic: nil) -> Integer` (how many images were queued)
  - `Boards::AdminBuilder::ArtQueue::BATCH_SIZE == 3`
  - `POST /admin/board_builds/:id/regenerate_art` → redirects to `show`. Route helper `regenerate_art_admin_dashboard_board_build_path(build)`.

- [ ] **Step 1: Write the failing test**

Create `spec/services/boards/admin_builder/art_queue_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Boards::AdminBuilder::ArtQueue do
  let!(:seed_admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }
  let(:board) { Board.create!(name: "Playground", slug: "playground-art", user: seed_admin) }

  before { GenerateImagesJob.jobs.clear }

  def image(label, prompt: nil)
    Image.create!(label: label, user: seed_admin, image_prompt: prompt)
  end

  it "queues in batches of three" do
    ids = 7.times.map { |n| image("word#{n}").id }

    expect(described_class.call(board: board, image_ids: ids)).to eq(7)
    expect(GenerateImagesJob.jobs.size).to eq(3)
    expect(GenerateImagesJob.jobs.map { |job| job["args"].first.size }).to eq([3, 3, 1])
    expect(GenerateImagesJob.jobs.first["args"].last).to eq(board.id)
  end

  it "does nothing when there is nothing to queue" do
    expect(described_class.call(board: board, image_ids: [])).to eq(0)
    expect(GenerateImagesJob.jobs).to be_empty
  end

  it "deduplicates ids" do
    id = image("swing").id

    expect(described_class.call(board: board, image_ids: [id, id])).to eq(1)
  end

  # The topic is what keeps "swing" on a playground board from coming back as a
  # mood swing.
  it "seeds a blank prompt with the label in the board's context" do
    swing = image("swing")

    described_class.call(board: board, image_ids: [swing.id], topic: "the playground")

    expect(swing.reload.image_prompt).to eq("swing in the context of the playground")
  end

  it "seeds a blank prompt with the bare label when there is no topic" do
    swing = image("swing")

    described_class.call(board: board, image_ids: [swing.id])

    expect(swing.reload.image_prompt).to eq("swing")
  end

  # Images::PromptBuilder composes the house style envelope at generation time;
  # an existing prompt is intent someone chose and must not be rewritten.
  it "leaves an existing prompt alone" do
    swing = image("swing", prompt: "a hand-written intent")

    described_class.call(board: board, image_ids: [swing.id], topic: "the playground")

    expect(swing.reload.image_prompt).to eq("a hand-written intent")
  end
end
```

Append to `spec/requests/admin/board_builds_spec.rb`:

```ruby
  describe "POST regenerate_art" do
    before do
      sign_in admin
      GenerateImagesJob.jobs.clear
    end

    def board_with_art_less_tile(board)
      image = Image.create!(label: "swing", user: seed_admin)
      board.add_image(image.id)
      image
    end

    it "queues generation for tiles with no picture" do
      board = built_board
      image = board_with_art_less_tile(board)
      build = create_build(board: board, status: "complete", topic: "the playground")

      post regenerate_art_admin_dashboard_board_build_path(build)

      expect(response).to redirect_to(admin_dashboard_board_build_path(build))
      expect(GenerateImagesJob.jobs.size).to eq(1)
      expect(GenerateImagesJob.jobs.first["args"].first).to include(image.id)
    end

    it "says so and queues nothing when every tile has a picture" do
      board = built_board
      build = create_build(board: board, status: "complete")

      post regenerate_art_admin_dashboard_board_build_path(build)

      expect(GenerateImagesJob.jobs).to be_empty
      expect(flash[:notice]).to match(/every tile/i)
    end

    it "cannot reach a board this page didn't create" do
      other = Board.create!(name: "Someone Else's", slug: "someone-elses-art", user: seed_admin)
      board_with_art_less_tile(other)
      build = create_build(board: other, status: "complete")

      post regenerate_art_admin_dashboard_board_build_path(build)

      expect(GenerateImagesJob.jobs).to be_empty
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/services/boards/admin_builder/art_queue_spec.rb spec/requests/admin/board_builds_spec.rb -e "regenerate_art"`
Expected: FAIL — `uninitialized constant Boards::AdminBuilder::ArtQueue` and undefined route helper.

- [ ] **Step 3: Write the service**

Create `app/services/boards/admin_builder/art_queue.rb`:

```ruby
module Boards
  module AdminBuilder
    # Seeds art prompts and queues generation for images that have no picture.
    #
    # Extracted so the build path and the "try again" button on the build page
    # cannot drift: the batch size, the prompt-seeding rule and the
    # never-overwrite rule are stated once.
    module ArtQueue
      # Matches API::Internal::BoardImagesController's slicing: the job fans out
      # to an image API and a whole set in one call would stampede it.
      BATCH_SIZE = 3

      module_function

      # Returns how many images were queued.
      def call(board:, image_ids:, topic: nil)
        ids = Array(image_ids).compact.uniq
        return 0 if ids.empty?

        seed_prompts!(ids, topic)
        ids.each_slice(BATCH_SIZE) { |batch| GenerateImagesJob.perform_async(batch, board.id) }
        ids.size
      end

      # `image_prompt` carries the INTENT only — Images::PromptBuilder composes
      # the house style envelope at generation time and must never have it
      # baked in here, or it gets wrapped twice. An existing prompt is intent
      # someone already chose, so it is never rewritten.
      def seed_prompts!(image_ids, topic)
        Image.where(id: image_ids).each do |image|
          next if image.image_prompt.present?

          image.update_column(:image_prompt, art_intent_for(image.label, topic))
        end
      end

      # The board's topic is what keeps "swing" on a playground board from
      # coming back as a mood swing.
      def art_intent_for(label, topic)
        topic = topic.to_s.strip
        return label.to_s if topic.blank?

        "#{label} in the context of #{topic}"
      end
    end
  end
end
```

- [ ] **Step 4: Point `Build` at it**

In `app/services/boards/admin_builder/build.rb`:

Delete the `GENERATE_BATCH_SIZE` constant and its comment (lines 25-26).

Replace `queue_missing_art!`, `seed_art_prompts!` and `art_intent_for` (lines 235-262) with:

```ruby
      # Queued after commit: Sidekiq can otherwise pick the job up before the
      # rows it references exist.
      def queue_missing_art!(root, image_ids)
        ArtQueue.call(board: root, image_ids: image_ids, topic: build.topic)
      end
```

- [ ] **Step 5: Run the service specs**

Run: `bundle exec rspec spec/services/boards/admin_builder`
Expected: PASS, including the existing `build_spec.rb`.

- [ ] **Step 6: Add the route and action**

In `config/routes.rb`, in the `board_builds` member block:

```ruby
        post :regenerate_art
```

In `app/controllers/admin/board_builds_controller.rb`, extend the `before_action`:

```ruby
    before_action :set_build, only: %i[show update destroy publish unpublish duplicate regenerate_art]
```

Add the action after `unpublish`:

```ruby
    # Art generation can fail or be missed; the build page already counts what
    # has no picture, so give it a way to act on the count. Recomputed from the
    # boards rather than replayed from art_report, so a tile whose art arrived
    # since isn't generated twice.
    def regenerate_art
      set = @build.set_boards
      root = builder_board_for(@build)
      image_ids = set.flat_map { |page| art_less_image_ids(page) }.uniq

      if root.nil? || image_ids.empty?
        return redirect_to admin_dashboard_board_build_path(@build),
                           notice: "Every tile already has a picture — nothing to generate."
      end

      queued = Boards::AdminBuilder::ArtQueue.call(board: root, image_ids: image_ids, topic: @build.topic)
      redirect_to admin_dashboard_board_build_path(@build),
                  notice: "Queued art for #{queued} #{"tile".pluralize(queued)}."
    end
```

Add the private helper beside `missing_art_count`, and make `missing_art_count` use it:

```ruby
    def art_less_image_ids(board)
      Image.where(id: board.board_images.select(:image_id)).where.missing(:docs).pluck(:id)
    end

    def missing_art_count(board)
      art_less_image_ids(board).size
    end
```

- [ ] **Step 7: Add the button**

In `app/views/admin/board_builds/show.html.erb`, inside the "Art coverage" card, after the closing `</p>` of the missing-labels paragraph (currently line 97):

```erb
    <% if @missing_art_count.positive? %>
      <%= button_to "Generate the missing art", regenerate_art_admin_dashboard_board_build_path(@build), method: :post,
            class: "text-xs font-medium px-3 py-2 rounded border admin-input cursor-pointer text-t1 mt-3",
            form: { data: { turbo_confirm: "Queue AI art for #{@missing_art_count} #{"tile".pluralize(@missing_art_count)}?" } } %>
    <% end %>
```

- [ ] **Step 8: Run the tests**

Run: `bundle exec rspec spec/services/boards/admin_builder spec/requests/admin/board_builds_spec.rb spec/models/admin_board_build_spec.rb`
Expected: PASS

- [ ] **Step 9: Update the docs**

In `.claude-notes/board-builder.md`, add to the admin Board Builder section:

```markdown
- **`Boards::AdminBuilder::ArtQueue` is the single art-queueing path** — the
  build and the build page's "generate the missing art" button both go through
  it, so the batch size, the topic-flavoured `image_prompt` seed, and the rule
  that an existing prompt is never rewritten are stated once. The button
  recomputes what has no picture from the boards rather than replaying
  `art_report`, so a tile whose art arrived since isn't generated twice.
- **`GET /admin/board_builds/:id/duplicate`** loads a past build back into the
  form (writes nothing), and `preview` warns — never blocks — when a board of
  the same name already exists in `Board.public_boards` or
  `AdminBoardBuild.builder_boards`.
```

Add to `CHANGELOG.md`:

```markdown
- Admin Board Builder: duplicate a past build into the form, a duplicate-name warning at preview, and a button to generate missing tile art.
```

- [ ] **Step 10: Run the full admin and builder suites**

Run: `bundle exec rspec spec/services/boards spec/requests/admin spec/models/admin_board_build_spec.rb`
Expected: PASS, zero failures.

- [ ] **Step 11: Commit**

```bash
git add app/services/boards/admin_builder/art_queue.rb spec/services/boards/admin_builder/art_queue_spec.rb app/services/boards/admin_builder/build.rb config/routes.rb app/controllers/admin/board_builds_controller.rb app/views/admin/board_builds/show.html.erb spec/requests/admin/board_builds_spec.rb .claude-notes/board-builder.md CHANGELOG.md
git commit -m "feat(admin): re-queue missing tile art from the build page"
```

---

## Verification checklist

Before declaring the work done:

- [ ] `bundle exec rspec spec/services/boards spec/requests/admin spec/models/admin_board_build_spec.rb` passes with zero failures.
- [ ] The pre-existing assertion that `preview` changes neither `Board.count` nor `Image.count` still passes.
- [ ] `.claude-notes/board-builder.md` describes `WordList`, `SetDrafter`, `MetadataSuggester` and `ArtQueue`, and the root-only tagging rule.
- [ ] `CHANGELOG.md` has an entry per phase.
- [ ] No new AI service creates or updates a record.
