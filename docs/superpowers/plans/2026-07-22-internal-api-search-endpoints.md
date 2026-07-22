# Internal API Search Endpoints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add label-based image search and tag/name/description board search to the internal API so the printables pipeline can find content and download print-resolution originals from S3.

**Architecture:** Four new read-only endpoints under the existing `namespace :internal`, backed by two query objects (`Images::LabelSearch`, `Boards::AdminSearch`) and one licensing service (`Images::CommercialLicense`). Controllers stay thin. No new models, no migrations, no changes to existing endpoints.

**Tech Stack:** Rails 8, PostgreSQL, pg_search (existing scopes), Kaminari, RSpec + FactoryBot.

**Spec:** `docs/superpowers/specs/2026-07-22-internal-api-search-endpoints-design.md`

## Global Constraints

- All four endpoints inherit `API::Internal::ApplicationController` — bearer `INTERNAL_API_KEY` auth, `current_user` is always `User::DEFAULT_ADMIN_ID`. Do not add per-user auth.
- **Read-only.** No endpoint in this plan writes, deletes, or enqueues a job.
- Never read `Image#license` — it has zero populated rows. License data lives on `Doc#license`, keyed **`type`** (not `license`).
- Error semantics per `CLAUDE.md`: validation failures are **422** (`unprocessable_content`). Never 402 or 429. Never leak internal errors — generic messages only.
- Standard Ruby style, snake_case, fat models / thin controllers.
- Specs: prefer `FactoryBot.build` over `create` where the record needn't persist. Active Storage is Disk-backed in test — never touch real S3.
- Services needing `User::DEFAULT_ADMIN_ID` must create it explicitly in specs:
  `User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)`
- Commit after every task. Conventional Commit prefixes (`feat:`, `test:`, `docs:`).
- Branch: `claude/internal-endpoint-image-search-202420` (already checked out in this worktree). Never commit to `main`.

---

### Task 1: `Images::CommercialLicense` service

The licensing predicate. Everything else depends on it, so it lands first with no HTTP surface.

**Files:**
- Create: `app/services/images/commercial_license.rb`
- Test: `spec/services/images/commercial_license_spec.rb`

**Interfaces:**
- Consumes: nothing (leaf).
- Produces:
  - `Images::CommercialLicense.for(doc, include_share_alike: false)` → returns a
    `Result` value object responding to `commercial_safe?`, `attribution_required?`,
    `share_alike?`, and `license` (the raw jsonb hash or nil).
  - `Images::CommercialLicense::COMMERCIAL_TYPES` → frozen array of allowlisted license type strings.

**Background the implementer needs:**

`Doc#license` is a jsonb column populated only on `ObfImport` docs. Real shape:

```ruby
{ "type" => "CC BY-NC-SA",
  "author_name" => "Sergio Palao",
  "author_url" => "http://www.catedu.es/arasaac/condiciones_uso.php",
  "copyright_notice_url" => "http://creativecommons.org/licenses/by-nc-sa/3.0/" }
```

`OpenSymbol`-sourced docs have no `Doc#license`; their license lives on the `OpenSymbol` row, reached via `doc.matching_open_symbols` (which is `OpenSymbol.where(search_string: doc.raw)`). `OpenSymbol#license` is a plain string using the same vocabulary.

Real license type strings measured in the library — the parser must handle all of these, including the inconsistent casing (`CC By` vs `CC BY`) and version suffixes:

`"CC BY-NC-SA"`, `"CC BY-SA"`, `"CC By"`, `"private"`, `"CC BY"`, `"CC BY-NC"`, `"public domain"`, `"CC By 3.0"`, `"CC By-SA 3.0"`, `"CC By-ND"`, `"GPL"`, `"CC By-SA"`

- [ ] **Step 1: Write the failing test**

Create `spec/services/images/commercial_license_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Images::CommercialLicense do
  def result_for(license:, source_type: "ObfImport", include_share_alike: false)
    doc = Doc.new(license: license, source_type: source_type)
    described_class.for(doc, include_share_alike: include_share_alike)
  end

  describe "generated images" do
    it "treats OpenAI-generated docs as safe with no obligations" do
      r = result_for(license: nil, source_type: "OpenAI")
      expect(r.commercial_safe?).to be true
      expect(r.attribution_required?).to be false
      expect(r.share_alike?).to be false
    end
  end

  describe "commercially usable licenses" do
    it "treats public domain as safe with no attribution" do
      r = result_for(license: { "type" => "public domain" })
      expect(r.commercial_safe?).to be true
      expect(r.attribution_required?).to be false
    end

    ["CC BY", "CC By", "CC By 3.0"].each do |type|
      it "treats #{type.inspect} as safe but attribution-required" do
        r = result_for(license: { "type" => type })
        expect(r.commercial_safe?).to be true
        expect(r.attribution_required?).to be true
        expect(r.share_alike?).to be false
      end
    end
  end

  describe "share-alike" do
    ["CC BY-SA", "CC By-SA 3.0"].each do |type|
      it "excludes #{type.inspect} by default" do
        r = result_for(license: { "type" => type })
        expect(r.commercial_safe?).to be false
        expect(r.share_alike?).to be true
        expect(r.attribution_required?).to be true
      end

      it "admits #{type.inspect} when include_share_alike is set" do
        r = result_for(license: { "type" => type }, include_share_alike: true)
        expect(r.commercial_safe?).to be true
        expect(r.share_alike?).to be true
      end
    end
  end

  describe "non-commercial licenses" do
    ["CC BY-NC-SA", "CC BY-NC"].each do |type|
      it "never treats #{type.inspect} as safe, even with include_share_alike" do
        r = result_for(license: { "type" => type }, include_share_alike: true)
        expect(r.commercial_safe?).to be false
        expect(r.attribution_required?).to be true
      end
    end
  end

  describe "fail-closed cases" do
    it "rejects the 'private' license type" do
      expect(result_for(license: { "type" => "private" }).commercial_safe?).to be false
    end

    it "rejects no-derivatives" do
      expect(result_for(license: { "type" => "CC By-ND" }).commercial_safe?).to be false
    end

    it "rejects an unrecognized license type" do
      expect(result_for(license: { "type" => "GPL" }).commercial_safe?).to be false
    end

    it "rejects a nil license" do
      expect(result_for(license: nil).commercial_safe?).to be false
    end

    it "rejects an empty license hash" do
      expect(result_for(license: {}).commercial_safe?).to be false
    end

    it "rejects scraped GoogleSearch docs" do
      expect(result_for(license: nil, source_type: "GoogleSearch").commercial_safe?).to be false
    end

    it "rejects docs with an unknown source_type" do
      expect(result_for(license: nil, source_type: nil).commercial_safe?).to be false
    end
  end

  describe "OpenSymbol-sourced docs" do
    it "resolves the license from the matching OpenSymbol row" do
      OpenSymbol.create!(search_string: "apple", label: "apple",
                         image_url: "https://example.com/a.png", license: "CC BY")
      doc = Doc.new(raw: "apple", source_type: "OpenSymbol", license: nil)

      r = described_class.for(doc)
      expect(r.commercial_safe?).to be true
      expect(r.attribution_required?).to be true
    end

    it "rejects a protected symbol regardless of its license string" do
      OpenSymbol.create!(search_string: "banana", label: "banana",
                         image_url: "https://example.com/b.png",
                         license: "CC BY", protected_symbol: "true")
      doc = Doc.new(raw: "banana", source_type: "OpenSymbol", license: nil)

      expect(described_class.for(doc).commercial_safe?).to be false
    end
  end

  describe "the returned license payload" do
    it "exposes the raw license hash for attribution rendering" do
      license = { "type" => "CC BY", "author_name" => "Sergio Palao",
                  "author_url" => "https://example.com/author" }
      expect(result_for(license: license).license).to eq(license)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/images/commercial_license_spec.rb`
Expected: FAIL — `uninitialized constant Images::CommercialLicense`

- [ ] **Step 3: Write the implementation**

Create `app/services/images/commercial_license.rb`:

```ruby
# app/services/images/commercial_license.rb
#
# Decides whether an image may appear in a product we SELL, and what
# obligations come with it.
#
# Grounded in the actual library (measured 2026-07-22, 10,101 docs) — see
# docs/superpowers/specs/2026-07-22-internal-api-search-endpoints-design.md
# for the full breakdown. Two facts drive the shape of this code:
#
#   * Doc#license is the ONLY populated license field (Image#license has zero
#     rows) and its jsonb key is "type", not "license".
#   * Doc#license is populated only on ObfImport docs. OpenSymbol-sourced docs
#     carry their license on the OpenSymbol row instead.
#
# The predicate FAILS CLOSED: anything unrecognized is unsafe. A false negative
# costs one missing picture; a false positive costs a license violation.
module Images
  module CommercialLicense
    # License types usable in a product we sell, with no share-alike burden.
    # Matched case-insensitively after normalization, so "CC By 3.0" and
    # "CC BY" both land on "cc by".
    COMMERCIAL_TYPES = [
      "public domain",
      "cc0",
      "cc by",
    ].freeze

    # source_types whose provenance we cannot vouch for. Scraped or unknown.
    UNTRUSTED_SOURCE_TYPES = ["GoogleSearch", nil, ""].freeze

    # We generated it; it's ours.
    OWNED_SOURCE_TYPE = "OpenAI".freeze

    Result = Struct.new(:license, :type, :commercial_safe, :attribution_required, :share_alike) do
      def commercial_safe? = !!commercial_safe
      def attribution_required? = !!attribution_required
      def share_alike? = !!share_alike
    end

    class << self
      def for(doc, include_share_alike: false)
        # Resolved once — for OpenSymbol docs this hits the DB.
        license = resolve_license(doc)
        protected_symbol = license == :protected
        license = nil if protected_symbol

        type = normalize_type(license.is_a?(Hash) ? license["type"] : license)

        share_alike    = type.present? && type.include?("sa")
        non_commercial = type.present? && type.include?("nc")
        no_derivatives = type.present? && type.include?("nd")
        attribution    = type.present? && type.start_with?("cc by")

        safe = safe?(
          doc: doc,
          type: type,
          protected_symbol: protected_symbol,
          share_alike: share_alike,
          non_commercial: non_commercial,
          no_derivatives: no_derivatives,
          include_share_alike: include_share_alike,
        )

        Result.new(license.is_a?(Hash) ? license : nil, type.presence, safe, attribution, share_alike)
      end

      private

      # OpenSymbol docs keep their license on the symbol row, not the doc.
      # Returns the jsonb hash, a license string, :protected, or nil.
      def resolve_license(doc)
        return doc.license if doc.license.present?
        return nil unless doc.source_type == "OpenSymbol"

        symbol = doc.matching_open_symbols.first
        return nil unless symbol
        return :protected if truthy?(symbol.protected_symbol)

        symbol.license
      end

      def safe?(doc:, type:, protected_symbol:, share_alike:, non_commercial:, no_derivatives:, include_share_alike:)
        return false if protected_symbol
        return true  if doc.source_type == OWNED_SOURCE_TYPE
        return false if UNTRUSTED_SOURCE_TYPES.include?(doc.source_type)
        return false if type.blank?
        return false if non_commercial || no_derivatives
        return false if share_alike && !include_share_alike

        # Strip the SA suffix before matching so "cc by-sa" can match "cc by"
        # once the caller has opted into share-alike.
        base = type.sub(/-sa\b/, "").strip
        COMMERCIAL_TYPES.any? { |allowed| base == allowed || base.start_with?("#{allowed} ") }
      end

      # "CC By-SA 3.0" -> "cc by-sa 3.0"; collapses whitespace so version
      # suffixes and casing inconsistencies in the library don't matter.
      def normalize_type(value)
        value.to_s.strip.downcase.gsub(/\s+/, " ")
      end

      def truthy?(value)
        ["true", "t", "1", true].include?(value.is_a?(String) ? value.downcase : value)
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/services/images/commercial_license_spec.rb`
Expected: PASS — all examples green.

If the `cc by` prefix matching misbehaves on `"CC By 3.0"`, check `normalize_type` output in isolation before changing the allowlist — the version suffix is handled by the `start_with?("#{allowed} ")` branch, not by the allowlist.

- [ ] **Step 5: Commit**

```bash
git add app/services/images/commercial_license.rb spec/services/images/commercial_license_spec.rb
git commit -m "feat: add Images::CommercialLicense licensing predicate

Fails closed: only OpenAI-generated, public domain, CC0 and CC BY images
are commercial-safe. Share-alike is opt-in; NC and ND never qualify.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `Images::LabelSearch` query object

Search + serialization for images, with no HTTP surface yet.

**Files:**
- Create: `app/services/images/label_search.rb`
- Test: `spec/services/images/label_search_spec.rb`

**Interfaces:**
- Consumes: `Images::CommercialLicense.for(doc, include_share_alike:)` from Task 1.
- Produces:
  - `Images::LabelSearch.new(match:, limit:, commercial_safe:, include_share_alike:)`
  - `#call(label)` → array of result hashes (see shape below), ordered exact-hits-first.
  - `Images::LabelSearch::MAX_LIMIT` = `50`

**Background the implementer needs:**

Existing scopes to compose (all already defined on `Image`):
- `Image.default_public` — `is_private` false/nil, `user_id` in `[nil, User::DEFAULT_ADMIN_ID]`
- `Image.searchable` — excludes `SampleVoice`
- `Image.with_artifacts` — eager-loads `docs → image_attachment → blob`
- `Image.search_by_exact_label(q)` / `Image.search_by_label(q)` — pg_search scopes

URL methods on `Doc`:
- `doc.tile_url` → 288px WebP tile variant (previews)
- `doc.display_url` → the untouched original blob on the CDN (**what printables download**)

Pick the doc via `image.display_doc(nil)` — passing nil makes it fall back to the image's own docs rather than a viewing user's.

- [ ] **Step 1: Write the failing test**

Create `spec/services/images/label_search_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Images::LabelSearch do
  let(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  # Attaches a real (tiny) blob so display_doc / display_url resolve.
  def image_with_doc(label:, user: admin, private_flag: false, license: nil, source_type: "OpenAI")
    image = Image.create!(label: label, user_id: user&.id, is_private: private_flag)
    doc = image.docs.create!(user_id: user&.id, license: license, source_type: source_type, raw: label)
    doc.image.attach(
      io: StringIO.new(file_fixture("sample.png").read),
      filename: "#{label}.png",
      content_type: "image/png",
    )
    image
  end

  before { admin }

  describe "matching" do
    it "returns an exact label match" do
      image_with_doc(label: "apple")
      results = described_class.new.call("apple")
      expect(results.map { |r| r[:label] }).to eq(["apple"])
      expect(results.first[:match]).to eq("exact")
    end

    it "falls back to prefix matching when no exact match exists" do
      image_with_doc(label: "applesauce")
      results = described_class.new.call("apple")
      expect(results.map { |r| r[:label] }).to eq(["applesauce"])
      expect(results.first[:match]).to eq("prefix")
    end

    it "skips the exact attempt when match: prefix" do
      image_with_doc(label: "applesauce")
      results = described_class.new(match: "prefix").call("apple")
      expect(results.first[:match]).to eq("prefix")
    end

    it "returns an empty array when nothing matches" do
      expect(described_class.new.call("nonexistentword")).to eq([])
    end
  end

  describe "scope" do
    it "excludes private images" do
      image_with_doc(label: "secret", private_flag: true)
      expect(described_class.new.call("secret")).to eq([])
    end

    it "excludes images owned by a non-admin user" do
      other = create(:user)
      image_with_doc(label: "theirs", user: other)
      expect(described_class.new.call("theirs")).to eq([])
    end

    it "excludes images with no attached doc" do
      Image.create!(label: "docless", user_id: admin.id)
      expect(described_class.new.call("docless")).to eq([])
    end
  end

  describe "limit" do
    it "clamps the limit to MAX_LIMIT" do
      expect(described_class.new(limit: 9_999).limit).to eq(described_class::MAX_LIMIT)
    end

    it "clamps a zero or negative limit up to 1" do
      expect(described_class.new(limit: 0).limit).to eq(1)
    end
  end

  describe "result shape" do
    it "returns both the tile URL and the full-resolution original" do
      image_with_doc(label: "apple")
      result = described_class.new.call("apple").first

      expect(result[:src]).to be_present
      expect(result[:original_url]).to be_present
      expect(result).to include(:id, :label, :match, :content_type, :width, :height,
                                :source_type, :license, :commercial_safe,
                                :attribution_required, :share_alike)
    end

    it "reports licensing flags from CommercialLicense" do
      image_with_doc(label: "arasaac", source_type: "ObfImport",
                     license: { "type" => "CC BY-NC-SA", "author_name" => "Sergio Palao" })
      result = described_class.new.call("arasaac").first

      expect(result[:commercial_safe]).to be false
      expect(result[:attribution_required]).to be true
      expect(result[:license]["author_name"]).to eq("Sergio Palao")
    end
  end

  describe "commercial_safe filtering" do
    it "omits unsafe images when commercial_safe is requested" do
      image_with_doc(label: "nc", source_type: "ObfImport", license: { "type" => "CC BY-NC" })
      expect(described_class.new(commercial_safe: true).call("nc")).to eq([])
    end

    it "keeps safe images when commercial_safe is requested" do
      image_with_doc(label: "mine", source_type: "OpenAI")
      expect(described_class.new(commercial_safe: true).call("mine").size).to eq(1)
    end

    it "returns unsafe images when commercial_safe is not requested" do
      image_with_doc(label: "nc2", source_type: "ObfImport", license: { "type" => "CC BY-NC" })
      expect(described_class.new.call("nc2").size).to eq(1)
    end

    it "admits share-alike images only with include_share_alike" do
      image_with_doc(label: "sa", source_type: "ObfImport", license: { "type" => "CC BY-SA" })

      expect(described_class.new(commercial_safe: true).call("sa")).to eq([])
      expect(described_class.new(commercial_safe: true, include_share_alike: true).call("sa").size).to eq(1)
    end
  end
end
```

- [ ] **Step 2: Create the spec file fixture**

The tests attach a real image. Create a 1×1 PNG at `spec/fixtures/files/sample.png`:

```bash
mkdir -p spec/fixtures/files
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' > spec/fixtures/files/sample.png
```

Verify it is a valid PNG: `file spec/fixtures/files/sample.png`
Expected: `spec/fixtures/files/sample.png: PNG image data, 1 x 1, RGBA, non-interlaced`

If `file_fixture` is not available, confirm `config.file_fixture_path` is set in `spec/rails_helper.rb`; if absent, add `config.file_fixture_path = "#{::Rails.root}/spec/fixtures/files"` inside the `RSpec.configure` block.

- [ ] **Step 3: Run test to verify it fails**

Run: `bundle exec rspec spec/services/images/label_search_spec.rb`
Expected: FAIL — `uninitialized constant Images::LabelSearch`

- [ ] **Step 4: Write the implementation**

Create `app/services/images/label_search.rb`:

```ruby
# app/services/images/label_search.rb
#
# Label search over the public image library for the internal API.
#
# Two things callers get wrong, so they are explicit in the payload:
#
#   * `src` is the 288px WebP tile (previews). `original_url` is the untouched
#     full-resolution upload — that is what a printable must download.
#   * licensing flags come from Images::CommercialLicense and are ALWAYS
#     present, whether or not the request filtered on them.
module Images
  class LabelSearch
    MAX_LIMIT = 50
    DEFAULT_LIMIT = 10

    attr_reader :match, :limit, :commercial_safe, :include_share_alike

    def initialize(match: "exact", limit: DEFAULT_LIMIT, commercial_safe: false, include_share_alike: false)
      @match = match.to_s == "prefix" ? "prefix" : "exact"
      @limit = clamp(limit)
      @commercial_safe = commercial_safe
      @include_share_alike = include_share_alike
    end

    def call(label)
      label = label.to_s.strip
      return [] if label.blank?

      matched, kind = fetch(label)
      matched.filter_map { |image| serialize(image, kind) }.first(limit)
    end

    private

    def base_scope
      Image.default_public.searchable.with_artifacts
    end

    # Exact first, prefix as a fallback — labels are stored inconsistently
    # enough that exact-only would produce spurious empty results.
    def fetch(label)
      if match == "prefix"
        [base_scope.search_by_label(label).limit(limit), "prefix"]
      else
        exact = base_scope.search_by_exact_label(label).limit(limit).to_a
        return [exact, "exact"] if exact.any?

        [base_scope.search_by_label(label).limit(limit), "prefix"]
      end
    end

    def serialize(image, kind)
      doc = image.display_doc(nil)
      return nil unless doc&.image&.attached?

      license = Images::CommercialLicense.for(doc, include_share_alike: include_share_alike)
      return nil if commercial_safe && !license.commercial_safe?

      blob = doc.image.blob

      {
        id: image.id,
        label: image.label,
        match: kind,
        src: doc.tile_url,
        original_url: doc.display_url,
        content_type: blob&.content_type,
        width: blob&.metadata&.dig("width"),
        height: blob&.metadata&.dig("height"),
        source_type: doc.source_type,
        license: license.license,
        commercial_safe: license.commercial_safe?,
        attribution_required: license.attribution_required?,
        share_alike: license.share_alike?,
      }
    end

    def clamp(value)
      value = value.to_i
      return DEFAULT_LIMIT if value.zero?

      value.clamp(1, MAX_LIMIT)
    end
  end
end
```

- [ ] **Step 5: Run the tests**

Run: `bundle exec rspec spec/services/images/label_search_spec.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/services/images/label_search.rb spec/services/images/label_search_spec.rb spec/fixtures/files/sample.png
git commit -m "feat: add Images::LabelSearch query object

Exact-then-prefix label matching over the public image library, returning
both the tile URL and the full-resolution original for print use.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Image search endpoints

Wire `Images::LabelSearch` to HTTP.

**Files:**
- Modify: `app/controllers/api/internal/images_controller.rb`
- Modify: `config/routes.rb` (the `namespace :internal` → `resources :images` collection block, around line 445)
- Test: `spec/requests/api/internal/images_search_spec.rb`

**Interfaces:**
- Consumes: `Images::LabelSearch` from Task 2.
- Produces:
  - `GET /api/internal/images/search` → `{ query:, results: [] }`
  - `POST /api/internal/images/search` → `{ results: { label => [] } }`
  - `API::Internal::ImagesController::MAX_BULK_LABELS` = `100`

- [ ] **Step 1: Write the failing test**

Create `spec/requests/api/internal/images_search_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "API::Internal::Images search", type: :request do
  let(:internal_key) { "test-internal-key" }
  let(:auth_headers) { { "Authorization" => "Bearer #{internal_key}" } }
  let(:json_headers) { auth_headers.merge("Content-Type" => "application/json") }
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INTERNAL_API_KEY").and_return(internal_key)
  end

  def image_with_doc(label:, source_type: "OpenAI", license: nil)
    image = Image.create!(label: label, user_id: admin.id)
    doc = image.docs.create!(user_id: admin.id, source_type: source_type, license: license, raw: label)
    doc.image.attach(
      io: StringIO.new(file_fixture("sample.png").read),
      filename: "#{label}.png",
      content_type: "image/png",
    )
    image
  end

  def body = JSON.parse(response.body)

  describe "GET /api/internal/images/search" do
    it "returns 401 without a valid bearer token" do
      get "/api/internal/images/search", params: { q: "apple" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 422 when q is blank" do
      get "/api/internal/images/search", params: { q: "" }, headers: auth_headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns matching images" do
      image_with_doc(label: "apple")
      get "/api/internal/images/search", params: { q: "apple" }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(body["query"]).to eq("apple")
      expect(body["results"].first["label"]).to eq("apple")
      expect(body["results"].first["original_url"]).to be_present
    end

    it "filters on commercial_safe when requested" do
      image_with_doc(label: "nc", source_type: "ObfImport", license: { "type" => "CC BY-NC" })
      get "/api/internal/images/search",
          params: { q: "nc", commercial_safe: "true" }, headers: auth_headers

      expect(body["results"]).to eq([])
    end

    it "admits share-alike images with include_share_alike" do
      image_with_doc(label: "sa", source_type: "ObfImport", license: { "type" => "CC BY-SA" })
      get "/api/internal/images/search",
          params: { q: "sa", commercial_safe: "true", include_share_alike: "true" },
          headers: auth_headers

      expect(body["results"].size).to eq(1)
    end
  end

  describe "POST /api/internal/images/search" do
    it "returns 401 without a valid bearer token" do
      post "/api/internal/images/search",
           params: { labels: ["apple"] }.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 422 when labels is missing" do
      post "/api/internal/images/search", params: {}.to_json, headers: json_headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 422 when labels is empty" do
      post "/api/internal/images/search", params: { labels: [] }.to_json, headers: json_headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 422 when labels exceeds the cap" do
      post "/api/internal/images/search",
           params: { labels: Array.new(101) { |i| "w#{i}" } }.to_json, headers: json_headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns a key for every requested label, including misses" do
      image_with_doc(label: "apple")
      post "/api/internal/images/search",
           params: { labels: ["apple", "nothinghere"] }.to_json, headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(body["results"].keys).to contain_exactly("apple", "nothinghere")
      expect(body["results"]["apple"].size).to eq(1)
      expect(body["results"]["nothinghere"]).to eq([])
    end

    it "keys results by the caller's label verbatim" do
      image_with_doc(label: "apple")
      post "/api/internal/images/search",
           params: { labels: ["  Apple  "] }.to_json, headers: json_headers

      expect(body["results"].keys).to eq(["  Apple  "])
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/requests/api/internal/images_search_spec.rb`
Expected: FAIL — routing errors (`No route matches [GET] "/api/internal/images/search"`)

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, find the internal images block (around line 445):

```ruby
      resources :images, only: [:create, :show] do
        collection do
          post :generate
        end
      end
```

Replace it with:

```ruby
      resources :images, only: [:create, :show] do
        collection do
          post :generate
          get :search
          post :search, action: :bulk_search
        end
      end
```

Verify: `bin/rails routes | grep "internal.*images"`
Expected: rows for both `GET` and `POST` on `/api/internal/images/search`.

- [ ] **Step 4: Add the controller actions**

In `app/controllers/api/internal/images_controller.rb`, add the cap constant directly under the class declaration:

```ruby
class API::Internal::ImagesController < API::Internal::ApplicationController
  # Bulk search is a per-label query loop; the cap keeps it off a table scan.
  MAX_BULK_LABELS = 100
```

Then add both actions above the `private` keyword:

```ruby
  # GET /api/internal/images/search?q=apple
  def search
    label = params[:q].to_s.strip

    if label.blank?
      render json: { error: "q is required" }, status: :unprocessable_content
      return
    end

    render json: { query: label, results: label_search.call(label) }
  end

  # POST /api/internal/images/search { labels: [...] }
  #
  # Every requested label gets a key in the response — including misses, as an
  # empty array — so the caller can spot gaps without diffing its request.
  def bulk_search
    labels = Array(params[:labels]).map(&:to_s)

    if labels.empty?
      render json: { error: "labels is required" }, status: :unprocessable_content
      return
    end

    if labels.size > MAX_BULK_LABELS
      render json: { error: "labels exceeds the maximum of #{MAX_BULK_LABELS}" },
             status: :unprocessable_content
      return
    end

    search = label_search(limit: params[:limit_per_label], default_limit: 3)
    render json: { results: labels.index_with { |label| search.call(label) } }
  end
```

And in the `private` section, add the builder:

```ruby
  def label_search(limit: nil, default_limit: nil)
    Images::LabelSearch.new(
      match: params[:match],
      limit: limit || params[:limit] || default_limit || Images::LabelSearch::DEFAULT_LIMIT,
      commercial_safe: truthy_param?(params[:commercial_safe]),
      include_share_alike: truthy_param?(params[:include_share_alike]),
    )
  end

  def truthy_param?(value)
    ["true", "1", true].include?(value.is_a?(String) ? value.downcase : value)
  end
```

- [ ] **Step 5: Run the tests**

Run: `bundle exec rspec spec/requests/api/internal/images_search_spec.rb`
Expected: PASS

- [ ] **Step 6: Confirm no regression on the existing image endpoints**

Run: `bundle exec rspec spec/requests/api/internal/images_spec.rb`
Expected: PASS — the create/generate/show actions are untouched.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/api/internal/images_controller.rb config/routes.rb spec/requests/api/internal/images_search_spec.rb
git commit -m "feat: add internal image search endpoints

GET /api/internal/images/search for a single label and POST for bulk
lookup (up to 100 labels), returning print-resolution originals and
licensing flags.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `Boards::AdminSearch` query object

**Files:**
- Create: `app/services/boards/admin_search.rb`
- Test: `spec/services/boards/admin_search_spec.rb`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `Boards::AdminSearch.new(q:, tags:, tag_match:, published:, limit:, page:)`
  - `#call` → a Kaminari-paginated `ActiveRecord::Relation` of `Board`
  - `Boards::AdminSearch.tag_counts(published: nil)` → `[{ tag:, count: }, ...]`
  - `Boards::AdminSearch::MAX_LIMIT` = `100`

**Background the implementer needs:**

Existing `Board` scopes:
- `main_boards` — already means `non_menus` **and** `sub_board` false/nil
- `not_builder_child` — excludes Board Builder sub-boards
- `with_all_tags(values)` / `with_any_tags(values)` — array-overlap scopes that split on commas and normalize each value
- `search_by_name(q)` — pg_search prefix tsearch on `name` only
- `Board.normalize_tag_value(tag)` — strip / downcase / collapse whitespace
- `with_artifacts` — eager-loads `preview_image_attachment` / `_blob`

`description` is **not** in any search scope. Match it with `ILIKE`, and do **not** widen `search_by_name` — that scope is used elsewhere.

pg_search relations do not compose with `.or`. Resolve each side to ids first.

- [ ] **Step 1: Write the failing test**

Create `spec/services/boards/admin_search_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Boards::AdminSearch do
  let(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  def admin_board(name:, description: nil, tags: [], published: false, **attrs)
    create(:board, user: admin, name: name, description: description,
                   tags: tags, published: published, sub_board: false, **attrs)
  end

  before { admin }

  describe "scope" do
    it "returns admin-owned top-level boards" do
      board = admin_board(name: "Animals")
      expect(described_class.new.call).to include(board)
    end

    it "excludes boards owned by another user" do
      other = create(:user)
      board = create(:board, user: other, name: "Animals", sub_board: false)
      expect(described_class.new.call).not_to include(board)
    end

    it "excludes sub-boards" do
      board = admin_board(name: "Sub", sub_board: true)
      expect(described_class.new.call).not_to include(board)
    end

    it "excludes menus" do
      board = admin_board(name: "Menu board", board_type: "menu")
      expect(described_class.new.call).not_to include(board)
    end

    it "excludes builder children" do
      board = admin_board(name: "Builder child", settings: { "builder_child" => true })
      expect(described_class.new.call).not_to include(board)
    end
  end

  describe "q matching" do
    it "matches on a name prefix" do
      board = admin_board(name: "Animals")
      expect(described_class.new(q: "anim").call).to include(board)
    end

    it "matches on a description substring" do
      board = admin_board(name: "Zoo", description: "all about animals here")
      expect(described_class.new(q: "animals").call).to include(board)
    end

    it "returns nothing when neither field matches" do
      admin_board(name: "Animals")
      expect(described_class.new(q: "spaceship").call).to be_empty
    end
  end

  describe "published filter" do
    it "returns both published and unpublished when unset" do
      published = admin_board(name: "Published one", published: true)
      draft = admin_board(name: "Draft one", published: false)
      results = described_class.new.call
      expect(results).to include(published, draft)
    end

    it "returns only published when published: true" do
      published = admin_board(name: "Published two", published: true)
      draft = admin_board(name: "Draft two", published: false)
      results = described_class.new(published: true).call
      expect(results).to include(published)
      expect(results).not_to include(draft)
    end

    it "returns only unpublished when published: false" do
      published = admin_board(name: "Published three", published: true)
      draft = admin_board(name: "Draft three", published: false)
      results = described_class.new(published: false).call
      expect(results).to include(draft)
      expect(results).not_to include(published)
    end
  end

  describe "tag filtering" do
    it "requires ALL tags by default" do
      both = admin_board(name: "Both", tags: ["printable", "core"])
      one = admin_board(name: "One", tags: ["printable"])
      results = described_class.new(tags: "printable,core").call
      expect(results).to include(both)
      expect(results).not_to include(one)
    end

    it "requires ANY tag when tag_match is any" do
      one = admin_board(name: "One any", tags: ["printable"])
      expect(described_class.new(tags: "printable,core", tag_match: "any").call).to include(one)
    end

    it "normalizes tag values" do
      board = admin_board(name: "Normalized", tags: ["printable"])
      expect(described_class.new(tags: "  Printable  ").call).to include(board)
    end

    it "ANDs tags with q" do
      match = admin_board(name: "Animals", tags: ["printable"])
      wrong_tag = admin_board(name: "Animals two", tags: ["other"])
      results = described_class.new(q: "anim", tags: "printable").call
      expect(results).to include(match)
      expect(results).not_to include(wrong_tag)
    end
  end

  describe "limit" do
    it "clamps to MAX_LIMIT" do
      expect(described_class.new(limit: 9_999).limit).to eq(described_class::MAX_LIMIT)
    end
  end

  describe ".tag_counts" do
    it "counts tags across admin boards" do
      admin_board(name: "A", tags: ["printable", "core"])
      admin_board(name: "B", tags: ["printable"])

      counts = described_class.tag_counts
      expect(counts.find { |c| c[:tag] == "printable" }[:count]).to eq(2)
      expect(counts.find { |c| c[:tag] == "core" }[:count]).to eq(1)
    end

    it "includes tags that appear only on unpublished boards" do
      admin_board(name: "Draft tagged", tags: ["draftonly"], published: false)
      expect(described_class.tag_counts.map { |c| c[:tag] }).to include("draftonly")
    end

    it "respects the published filter" do
      admin_board(name: "Draft tagged two", tags: ["draftonly2"], published: false)
      expect(described_class.tag_counts(published: true).map { |c| c[:tag] })
        .not_to include("draftonly2")
    end

    it "orders by count descending" do
      admin_board(name: "C", tags: ["common", "rare"])
      admin_board(name: "D", tags: ["common"])
      counts = described_class.tag_counts
      expect(counts.first[:tag]).to eq("common")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/boards/admin_search_spec.rb`
Expected: FAIL — `uninitialized constant Boards::AdminSearch`

- [ ] **Step 3: Write the implementation**

Create `app/services/boards/admin_search.rb`:

```ruby
# app/services/boards/admin_search.rb
#
# Search over admin-owned boards for the internal API — published AND
# unpublished, filterable by tag, name and description.
#
# Two deliberate choices:
#
#   * `q` matches name via pg_search (prefix) OR description via ILIKE
#     (substring). Those aren't comparably ranked, so results order by
#     updated_at desc rather than faking a combined relevance score.
#   * `description` is NOT added to Board.search_by_name — that scope is used
#     elsewhere and widening it would silently change existing results.
module Boards
  class AdminSearch
    MAX_LIMIT = 100
    DEFAULT_LIMIT = 25

    attr_reader :q, :tags, :tag_match, :published, :limit, :page

    def initialize(q: nil, tags: nil, tag_match: "all", published: nil, limit: DEFAULT_LIMIT, page: 1)
      @q = q.to_s.strip
      @tags = tags
      @tag_match = tag_match.to_s == "any" ? "any" : "all"
      @published = published
      @limit = clamp(limit)
      @page = [page.to_i, 1].max
    end

    def call
      scope = self.class.base_scope
      scope = apply_published(scope)
      scope = apply_tags(scope)
      scope = apply_query(scope)
      scope.with_artifacts.order(updated_at: :desc).page(page).per(limit)
    end

    # Top-level admin boards a human would recognize. main_boards already
    # covers non_menus + not a sub_board.
    def self.base_scope
      Board.where(user_id: User::DEFAULT_ADMIN_ID).main_boards.not_builder_child
    end

    def self.tag_counts(published: nil)
      scope = base_scope
      scope = scope.where(published: published) unless published.nil?

      scope
        .select(Arel.sql("unnest(tags) AS tag"))
        .then { |inner| Board.from(inner, :tags_expanded) }
        .group("tag")
        .order(Arel.sql("COUNT(*) DESC, tag ASC"))
        .count
        .map { |tag, count| { tag: tag, count: count } }
    end

    private

    def apply_published(scope)
      return scope if published.nil?

      scope.where(published: published)
    end

    def apply_tags(scope)
      return scope if tags.blank?

      tag_match == "any" ? scope.with_any_tags(tags) : scope.with_all_tags(tags)
    end

    # pg_search relations don't compose with .or, so resolve each side to ids.
    def apply_query(scope)
      return scope if q.blank?

      name_ids = Board.search_by_name(q).pluck(:id)
      desc_ids = Board.where("boards.description ILIKE ?", "%#{sanitize_like(q)}%").pluck(:id)

      scope.where(id: (name_ids + desc_ids).uniq)
    end

    def sanitize_like(value)
      ActiveRecord::Base.sanitize_sql_like(value)
    end

    def clamp(value)
      value = value.to_i
      return DEFAULT_LIMIT if value.zero?

      value.clamp(1, MAX_LIMIT)
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/services/boards/admin_search_spec.rb`
Expected: PASS

If `.tag_counts` raises a SQL error about the subquery, the `Board.from(...)` form may need to be a raw `select_all` instead:

```ruby
    def self.tag_counts(published: nil)
      scope = base_scope
      scope = scope.where(published: published) unless published.nil?

      sql = "SELECT tag, COUNT(*) AS count FROM (#{scope.select(Arel.sql('unnest(tags) AS tag')).to_sql}) AS t " \
            "GROUP BY tag ORDER BY COUNT(*) DESC, tag ASC"
      ActiveRecord::Base.connection.select_all(sql).map do |row|
        { tag: row["tag"], count: row["count"].to_i }
      end
    end
```

Use whichever passes; prefer the Arel form if it works.

- [ ] **Step 5: Commit**

```bash
git add app/services/boards/admin_search.rb spec/services/boards/admin_search_spec.rb
git commit -m "feat: add Boards::AdminSearch query object

Tag / name / description search over admin-owned top-level boards, with
an optional published filter and tag-count discovery.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Board search endpoints

**Files:**
- Modify: `app/controllers/api/internal/boards_controller.rb`
- Modify: `config/routes.rb` (internal `resources :boards` collection block, around line 427)
- Test: `spec/requests/api/internal/boards_search_spec.rb`

**Interfaces:**
- Consumes: `Boards::AdminSearch` from Task 4.
- Produces:
  - `GET /api/internal/boards/search` → `{ results: [], page:, total_pages:, total_count: }`
  - `GET /api/internal/boards/tags` → `{ tags: [{ tag:, count: }] }`

**Background:** the lean payload is a private controller method, deliberately **not** a new `Board#*_api_view` — the model already carries five view methods (`api_view`, `list_api_view`, `api_view_with_images`, `api_view_with_predictive_images`, `api_view_for_native_grid`) and the existing ones pull `pdf_url` / `word_list` / communicator data, which would N+1 across a page of results.

- [ ] **Step 1: Write the failing test**

Create `spec/requests/api/internal/boards_search_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "API::Internal::Boards search", type: :request do
  let(:internal_key) { "test-internal-key" }
  let(:auth_headers) { { "Authorization" => "Bearer #{internal_key}" } }
  let!(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INTERNAL_API_KEY").and_return(internal_key)
  end

  def admin_board(name:, description: nil, tags: [], published: false, **attrs)
    create(:board, user: admin, name: name, description: description,
                   tags: tags, published: published, sub_board: false, **attrs)
  end

  def body = JSON.parse(response.body)

  describe "GET /api/internal/boards/search" do
    it "returns 401 without a valid bearer token" do
      get "/api/internal/boards/search"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns the full admin scope when no params are given" do
      admin_board(name: "Animals")
      get "/api/internal/boards/search", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(body["results"].map { |b| b["name"] }).to include("Animals")
      expect(body).to include("page", "total_pages", "total_count")
    end

    it "matches on a name prefix" do
      admin_board(name: "Animals")
      get "/api/internal/boards/search", params: { q: "anim" }, headers: auth_headers
      expect(body["results"].map { |b| b["name"] }).to eq(["Animals"])
    end

    it "matches on a description substring" do
      admin_board(name: "Zoo", description: "all about animals here")
      get "/api/internal/boards/search", params: { q: "animals" }, headers: auth_headers
      expect(body["results"].map { |b| b["name"] }).to eq(["Zoo"])
    end

    it "returns unpublished boards by default" do
      admin_board(name: "Draft board", published: false)
      get "/api/internal/boards/search", headers: auth_headers
      expect(body["results"].map { |b| b["name"] }).to include("Draft board")
    end

    it "filters to published only when asked" do
      admin_board(name: "Draft board", published: false)
      admin_board(name: "Live board", published: true)
      get "/api/internal/boards/search", params: { published: "true" }, headers: auth_headers

      names = body["results"].map { |b| b["name"] }
      expect(names).to include("Live board")
      expect(names).not_to include("Draft board")
    end

    it "requires all tags by default" do
      admin_board(name: "Both", tags: ["printable", "core"])
      admin_board(name: "One", tags: ["printable"])
      get "/api/internal/boards/search", params: { tags: "printable,core" }, headers: auth_headers

      expect(body["results"].map { |b| b["name"] }).to eq(["Both"])
    end

    it "requires any tag when tag_match is any" do
      admin_board(name: "One", tags: ["printable"])
      get "/api/internal/boards/search",
          params: { tags: "printable,core", tag_match: "any" }, headers: auth_headers

      expect(body["results"].map { |b| b["name"] }).to include("One")
    end

    it "returns the lean payload shape" do
      admin_board(name: "Animals", description: "zoo", tags: ["printable"], published: true)
      get "/api/internal/boards/search", params: { q: "anim" }, headers: auth_headers

      expect(body["results"].first).to include(
        "id", "slug", "name", "description", "tags", "published", "predefined",
        "board_type", "image_count", "preview_image_url", "created_at", "updated_at"
      )
    end

    it "excludes boards owned by another user" do
      other = create(:user)
      create(:board, user: other, name: "Theirs", sub_board: false)
      get "/api/internal/boards/search", params: { q: "Theirs" }, headers: auth_headers

      expect(body["results"]).to eq([])
    end
  end

  describe "GET /api/internal/boards/tags" do
    it "returns 401 without a valid bearer token" do
      get "/api/internal/boards/tags"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns tags with counts" do
      admin_board(name: "A", tags: ["printable", "core"])
      admin_board(name: "B", tags: ["printable"])
      get "/api/internal/boards/tags", headers: auth_headers

      expect(response).to have_http_status(:ok)
      printable = body["tags"].find { |t| t["tag"] == "printable" }
      expect(printable["count"]).to eq(2)
    end

    it "includes tags found only on unpublished boards" do
      admin_board(name: "Draft", tags: ["draftonly"], published: false)
      get "/api/internal/boards/tags", headers: auth_headers

      expect(body["tags"].map { |t| t["tag"] }).to include("draftonly")
    end

    it "respects the published filter" do
      admin_board(name: "Draft", tags: ["draftonly"], published: false)
      get "/api/internal/boards/tags", params: { published: "true" }, headers: auth_headers

      expect(body["tags"].map { |t| t["tag"] }).not_to include("draftonly")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/requests/api/internal/boards_search_spec.rb`
Expected: FAIL — `No route matches [GET] "/api/internal/boards/search"`

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, the internal boards block currently reads:

```ruby
      resources :boards, only: [:create, :update, :show] do
        collection do
          post :from_vocab_set
        end
```

Add the two GET routes to that same collection block:

```ruby
      resources :boards, only: [:create, :update, :show] do
        collection do
          post :from_vocab_set
          get :search
          get :tags
        end
```

Verify: `bin/rails routes | grep "internal.*boards"`
Expected: rows for `/api/internal/boards/search` and `/api/internal/boards/tags`.

Note: these must be **collection** routes so they aren't shadowed by the `:show` member route (`/api/internal/boards/:id`). If `search` resolves to `show` with `id="search"`, the route was added in the wrong block.

- [ ] **Step 4: Add the controller actions**

In `app/controllers/api/internal/boards_controller.rb`, add both actions above the `private` keyword:

```ruby
  # GET /api/internal/boards/search
  #
  # Returns unpublished boards by DEFAULT. A caller building a sellable
  # product must pass published=true — this endpoint will not assume it.
  def search
    boards = Boards::AdminSearch.new(
      q: params[:q],
      tags: params[:tags],
      tag_match: params[:tag_match],
      published: published_filter,
      limit: params[:limit],
      page: params[:page],
    ).call

    render json: {
      results: boards.map { |board| search_result_view(board) },
      page: boards.current_page,
      total_pages: boards.total_pages,
      total_count: boards.total_count,
    }
  end

  # GET /api/internal/boards/tags
  def tags
    render json: { tags: Boards::AdminSearch.tag_counts(published: published_filter) }
  end
```

And in the `private` section:

```ruby
  # Deliberately NOT a Board#*_api_view — the model already carries five, and
  # the existing ones pull pdf_url / word_list / communicator data that would
  # N+1 across a page of search results.
  def search_result_view(board)
    {
      id: board.id,
      slug: board.slug,
      name: board.name,
      description: board.description,
      tags: board.tags,
      published: board.published,
      predefined: board.predefined,
      board_type: board.board_type,
      image_count: board.board_images_count,
      preview_image_url: board.preview_image_url,
      created_at: board.created_at,
      updated_at: board.updated_at,
    }
  end

  # nil (absent) means "both" — not false.
  def published_filter
    return nil if params[:published].blank?

    ["true", "1"].include?(params[:published].to_s.downcase)
  end
```

- [ ] **Step 5: Run the tests**

Run: `bundle exec rspec spec/requests/api/internal/boards_search_spec.rb`
Expected: PASS

- [ ] **Step 6: Confirm no regression on the existing board endpoints**

Run: `bundle exec rspec spec/requests/api/internal/boards_spec.rb spec/requests/api/internal/boards_from_vocab_set_spec.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add app/controllers/api/internal/boards_controller.rb config/routes.rb spec/requests/api/internal/boards_search_spec.rb
git commit -m "feat: add internal board search and tag endpoints

GET /api/internal/boards/search filters admin-owned boards by tag, name
and description, published or not. GET /api/internal/boards/tags returns
tag counts for discovery.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: License audit rake task

**Files:**
- Create: `lib/tasks/image_licenses.rake`
- Test: `spec/lib/tasks/image_licenses_rake_spec.rb`

**Interfaces:**
- Consumes: `Images::CommercialLicense` from Task 1.
- Produces: `rake images:license_audit` (read-only, prints to stdout).

- [ ] **Step 1: Write the failing test**

Create `spec/lib/tasks/image_licenses_rake_spec.rb`:

```ruby
require "rails_helper"
require "rake"

RSpec.describe "images:license_audit", type: :task do
  let(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  before(:all) do
    Rake.application.rake_require("tasks/image_licenses") unless Rake::Task.task_defined?("images:license_audit")
    Rake::Task.define_task(:environment)
  end

  before do
    admin
    Rake::Task["images:license_audit"].reenable
  end

  def doc_with(license:, source_type:)
    image = Image.create!(label: "audit-#{SecureRandom.hex(4)}", user_id: admin.id)
    image.docs.create!(user_id: admin.id, license: license, source_type: source_type, raw: image.label)
  end

  it "reports counts by license type" do
    doc_with(license: { "type" => "CC BY-NC-SA" }, source_type: "ObfImport")

    expect { Rake::Task["images:license_audit"].invoke }
      .to output(/CC BY-NC-SA/).to_stdout
  end

  it "reports the commercial-safe total" do
    doc_with(license: nil, source_type: "OpenAI")

    expect { Rake::Task["images:license_audit"].invoke }
      .to output(/commercial-safe/i).to_stdout
  end

  it "does not modify any records" do
    doc_with(license: { "type" => "CC BY" }, source_type: "ObfImport")
    before_updated = Doc.maximum(:updated_at)

    expect { Rake::Task["images:license_audit"].invoke }.to output.to_stdout
    expect(Doc.maximum(:updated_at)).to eq(before_updated)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/lib/tasks/image_licenses_rake_spec.rb`
Expected: FAIL — cannot load `tasks/image_licenses`

- [ ] **Step 3: Write the rake task**

Create `lib/tasks/image_licenses.rake`:

```ruby
# Read-only audit of what the image library is actually licensed under.
#
# The figures in the search-endpoints spec were measured 2026-07-22 and WILL
# drift as the library grows. Re-run this against production to refresh them
# before making a licensing decision.
#
#   bundle exec rake images:license_audit
namespace :images do
  desc "Report the license breakdown of the image library (read-only)"
  task license_audit: :environment do
    docs = Doc.includes(:image_attachment).where(deleted_at: nil)
    total = docs.count

    by_source = Hash.new(0)
    by_type   = Hash.new(0)
    safe = attribution = share_alike = 0

    docs.find_each do |doc|
      result = Images::CommercialLicense.for(doc)

      by_source[doc.source_type || "(none)"] += 1
      by_type[result.type || "(no license)"] += 1

      safe        += 1 if result.commercial_safe?
      attribution += 1 if result.attribution_required?
      share_alike += 1 if result.share_alike?
    end

    puts "\nImage library license audit — #{total} docs\n\n"

    puts "By source_type:"
    by_source.sort_by { |_, count| -count }.each { |name, count| puts format("  %-16s %6d", name, count) }

    puts "\nBy license type:"
    by_type.sort_by { |_, count| -count }.each { |name, count| puts format("  %-16s %6d", name, count) }

    puts "\nTotals:"
    puts format("  %-24s %6d  (%.1f%%)", "commercial-safe", safe, percent(safe, total))
    puts format("  %-24s %6d", "attribution-required", attribution)
    puts format("  %-24s %6d", "share-alike", share_alike)
    puts "\nNote: share-alike images are NOT counted as commercial-safe unless"
    puts "the caller passes include_share_alike. See the search-endpoints spec.\n\n"
  end

  def percent(part, whole)
    return 0.0 if whole.zero?

    (part.to_f / whole) * 100
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bundle exec rspec spec/lib/tasks/image_licenses_rake_spec.rb`
Expected: PASS

- [ ] **Step 5: Run the task against the dev database**

Run: `bundle exec rake images:license_audit`
Expected: a printed breakdown. Sanity-check it against the spec's table — `CC BY-NC-SA` should be the largest licensed bucket and `OpenAI` the largest source.

- [ ] **Step 6: Commit**

```bash
git add lib/tasks/image_licenses.rake spec/lib/tasks/image_licenses_rake_spec.rb
git commit -m "feat: add images:license_audit rake task

Read-only report of the library's license breakdown, so the numbers in
the search-endpoints spec can be refreshed as the library grows.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Documentation

The README is the deliverable Brittany explicitly asked for — it must make the internal API easy to use without reading the code.

**Files:**
- Modify: `README.md` (the `## Internal API` section, starting line 276)
- Create: `.claude-notes/internal-api.md` (must be `git add -f` — the directory is gitignored)
- Modify: `CLAUDE.md` (subsystem map table)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add the endpoint index to the README**

In `README.md`, immediately after the `### Setup` block's closing line
(`For Hatchbox, set INTERNAL_API_KEY in the app's environment variables panel.`)
and **before** `### Endpoints`, insert:

```markdown
### Endpoint index

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/internal/boards` | Create a board (optionally enqueue generation) |
| `POST` | `/api/internal/boards/from_vocab_set` | Clone a curated vocab-set board |
| `GET` | `/api/internal/boards/search` | Search admin boards by tag / name / description |
| `GET` | `/api/internal/boards/tags` | List admin board tags with counts |
| `GET` | `/api/internal/boards/:id` | Fetch one board with its tiles |
| `PATCH` | `/api/internal/boards/:id` | Update a board |
| `GET` | `/api/internal/boards/:id/export.pdf` | Render a board as a PDF |
| `POST` | `/api/internal/boards/:id/board_images` | Add a tile to a board |
| `POST` | `/api/internal/generated_boards` | Create a generated board |
| `GET` | `/api/internal/images/search` | Find images by label (single) |
| `POST` | `/api/internal/images/search` | Find images by label (bulk, ≤100) |
| `POST` | `/api/internal/images` | Create an image record |
| `POST` | `/api/internal/images/generate` | Generate an image via OpenAI (async) |
| `GET` | `/api/internal/images/:id` | Poll image generation status |
| `GET`/`POST` | `/api/internal/profiles/:id` | Read / update a communicator profile |
| `POST` | `/api/internal/marketing_assets` | Host a marketing PDF at a stable slug |
| `GET` | `/api/internal/marketing_assets/:slug` | Fetch a hosted marketing PDF URL |
| `GET` | `/api/internal/marketing_artifacts/*.pdf` | Render generic classroom sheets |

**Two things to get right before building anything printable:**

1. **`src` is a thumbnail, `original_url` is the print file.** Image search
   returns both. `src` is a 288×288 WebP at quality 65 — fine on screen,
   unusable in print. Download `original_url`.
2. **Board search returns unpublished boards by default.** Pass
   `published=true` if you are building something you intend to ship.
```

- [ ] **Step 2: Document the image search endpoints in the README**

In `README.md`, immediately **before** the `#### POST /api/internal/images` heading, insert:

````markdown
#### `GET /api/internal/images/search`

Find images in the public library by label. Exact match first, falling back to
prefix matching when there is no exact hit.

```sh
curl -G https://<host>/api/internal/images/search \
  -H "Authorization: Bearer $INTERNAL_API_KEY" \
  --data-urlencode "q=apple" \
  --data-urlencode "limit=5"
```

Params: `q` *(required)*, `match` (`exact` default, or `prefix`), `limit`
(default 10, max 50), `commercial_safe` (default false),
`include_share_alike` (default false).

Response `200`:

```json
{
  "query": "apple",
  "results": [
    {
      "id": 123,
      "label": "apple",
      "match": "exact",
      "src": "https://cdn.../variants/xyz",
      "original_url": "https://cdn.../abc123",
      "content_type": "image/png",
      "width": 1024,
      "height": 1024,
      "source_type": "OpenAI",
      "license": null,
      "commercial_safe": true,
      "attribution_required": false,
      "share_alike": false
    }
  ]
}
```

**`original_url` is the full-resolution original** on the public CDN — fetch it
directly, no signing or proxying needed. `src` is the 288px WebP tile and must
not be used in print.

**Licensing.** Roughly a third of the library cannot be used in a product you
sell — ARASAAC symbols in particular are CC BY-NC-SA. Pass
`commercial_safe=true` to filter to images that can be. Share-alike licenses are
excluded from that filter by default; add `include_share_alike=true` to include
them. Images with `attribution_required: true` must credit `license.author_name`
visibly in the product. Run `bundle exec rake images:license_audit` for the
current library-wide breakdown.

#### `POST /api/internal/images/search`

Bulk label lookup — one round trip for a whole sheet. Max 100 labels.

```sh
curl -X POST https://<host>/api/internal/images/search \
  -H "Authorization: Bearer $INTERNAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{ "labels": ["apple", "dog", "run"], "limit_per_label": 3, "commercial_safe": true }'
```

Response `200` — **every requested label gets a key**, misses included, so you
can spot gaps without diffing against your request:

```json
{
  "results": {
    "apple": [ { "id": 123, "label": "apple", "...": "..." } ],
    "dog":   [ { "id": 456, "label": "dog",   "...": "..." } ],
    "run":   []
  }
}
```
````

- [ ] **Step 3: Document the board search endpoints in the README**

In `README.md`, immediately **before** the `#### GET /api/internal/boards/:id` heading, insert:

````markdown
#### `GET /api/internal/boards/search`

Search admin-owned boards by tag, name, or description. Returns top-level
boards only — menus, sub-boards and Board Builder children are excluded.

```sh
curl -G https://<host>/api/internal/boards/search \
  -H "Authorization: Bearer $INTERNAL_API_KEY" \
  --data-urlencode "q=animals" \
  --data-urlencode "tags=printable,core" \
  --data-urlencode "published=true"
```

Params (all optional — no params returns every admin board, paginated):

- `q` — matches board **name** (prefix) or **description** (substring)
- `tags` — comma-separated; normalized (case and whitespace insensitive)
- `tag_match` — `all` (default) or `any`
- `published` — `true` or `false`. **Omit and you get both.**
- `limit` (default 25, max 100), `page` (default 1)

Response `200`:

```json
{
  "results": [
    {
      "id": 5394,
      "slug": "core-words",
      "name": "Core Words",
      "description": "Starter core vocabulary board",
      "tags": ["printable", "core"],
      "published": true,
      "predefined": false,
      "board_type": "static",
      "image_count": 60,
      "preview_image_url": "https://cdn.../preview.webp",
      "created_at": "2026-05-01T12:00:00Z",
      "updated_at": "2026-07-01T09:30:00Z"
    }
  ],
  "page": 1,
  "total_pages": 3,
  "total_count": 61
}
```

Results are ordered by `updated_at` descending. Fetch a board's actual tiles
with `GET /api/internal/boards/:id`.

> **Unpublished boards are included unless you filter them out.** If you are
> building something to ship, pass `published=true`.

#### `GET /api/internal/boards/tags`

Every tag in use across admin boards, with counts — so you know what you can
filter on.

```sh
curl https://<host>/api/internal/boards/tags \
  -H "Authorization: Bearer $INTERNAL_API_KEY"
```

Accepts the same `published` filter. Response `200`:

```json
{ "tags": [ { "tag": "printable", "count": 12 }, { "tag": "marketing", "count": 4 } ] }
```
````

- [ ] **Step 4: Verify the README renders correctly**

Run: `grep -n "^#### \`GET /api/internal" README.md`
Expected: the new search headings appear in the internal API section, in the order boards-search → boards-tags → boards/:id, and images-search before images create.

Read the `## Internal API` section top to bottom once. Check that the endpoint index table matches the headings that actually follow it — a stale index is worse than none.

- [ ] **Step 5: Create the `.claude-notes/internal-api.md` spoke**

Create `.claude-notes/internal-api.md`:

```markdown
# Internal API — `/api/internal/`

> Authoritative doc for the internal API surface. Update this (not CLAUDE.md)
> when behavior changes. User-facing usage docs live in `README.md`.

Server-to-server API for trusted callers (the printables pipeline, internal
scripts). Not for the React frontend and never exposed to end users.

## Auth and identity

`API::Internal::ApplicationController` authenticates a bearer token against
`ENV["INTERNAL_API_KEY"]` with `ActiveSupport::SecurityUtils.secure_compare`,
and CSRF is skipped. There is **no per-user auth**: `current_user` is always
`User::DEFAULT_ADMIN_ID`, so every write is attributed to the admin. Any new
endpoint inherits this — do not add per-user scoping to this namespace.

## Downloads go straight to the CDN

Production Active Storage is S3 with `public: true`, and `CDN_HOST` is set, so
blob URLs are permanent and unsigned. Internal callers fetch bytes directly
from CloudFront. **Do not add proxy/streaming download endpoints or presigned
URLs** — they add cost and latency for no benefit.

The trap: `Doc#tile_url` is the 288×288 WebP q65 tile variant
(`ApplicationRecord::TILE_VARIANT_TRANSFORMATIONS`), while `Doc#display_url` is
the untouched original. Anything print-bound must use the original. Image
search returns both, as `src` and `original_url`.

## Licensing — `Images::CommercialLicense`

Single source of truth for "may this image go in something we sell."

- **`Doc#license` is the only populated license field.** `Image#license` has
  zero rows — never read it. The jsonb key is **`type`**, not `license`.
- `Doc#license` is populated only on `ObfImport` docs. `OpenSymbol`-sourced
  docs carry license data on the `OpenSymbol` row, reached via
  `Doc#matching_open_symbols`.
- `OpenSymbol#protected_symbol` is `false` on every row today — it is checked
  defensively but carries no real signal.
- **ARASAAC (author "Sergio Palao") is CC BY-NC-SA and is the single largest
  licensed source.** It cannot go in a paid product. Free lead magnets (the
  Classroom Kit) are fine.

Three flags per image: `commercial_safe`, `attribution_required`,
`share_alike`. The predicate **fails closed** — unrecognized licenses,
scraped `GoogleSearch` docs and unknown `source_type` are all unsafe. CC BY-SA
is excluded from `commercial_safe` by default (share-alike is plausibly viral
onto a sold derivative) and admitted only via `include_share_alike`.

Refresh the library-wide numbers with `bundle exec rake images:license_audit` —
they drift as the library grows.

## Search endpoints

- `GET|POST /api/internal/images/search` → `Images::LabelSearch`. Exact match
  first, prefix fallback. Scoped to `Image.default_public.searchable` — user
  and private images are never reachable, and this is not overridable.
- `GET /api/internal/boards/search` → `Boards::AdminSearch`. Scoped to
  `Board.where(user_id: DEFAULT_ADMIN_ID).main_boards.not_builder_child`.
  Returns **unpublished boards by default**; callers building shippable
  products must pass `published=true`.
- `GET /api/internal/boards/tags` → tag counts for discovery.

`q` on board search matches name via pg_search (prefix) OR description via
ILIKE (substring); the two aren't comparably ranked, so results order by
`updated_at desc` rather than a fake combined relevance. **Do not widen
`Board.search_by_name` to include description** — that scope is used elsewhere.

Board search results use a purpose-built lean payload, deliberately not one of
`Board`'s five `api_view*` methods, which pull `pdf_url` / `word_list` /
communicator data and would N+1 across a page.

## Related

`marketing-assets.md` documents the marketing-asset and artifact endpoints
(stable slugs, kit QR targets) in detail.
```

Then force-add it (the directory is gitignored):

```bash
git add -f .claude-notes/internal-api.md
```

- [ ] **Step 6: Add the spoke to the CLAUDE.md subsystem map**

In `CLAUDE.md`, in the subsystem map table, add this row after the
`marketing-assets.md` row:

```markdown
| `.claude-notes/internal-api.md` | Internal `/api/internal/` surface: bearer auth + admin identity, public-CDN download path (`src` vs `original_url`), image + board search endpoints, `Images::CommercialLicense` licensing rule |
```

- [ ] **Step 7: Add the CHANGELOG entry**

In `CHANGELOG.md`, add under the current unreleased section (create an
`## Unreleased` heading at the top if none exists):

```markdown
### Added

- Internal API image search (`GET`/`POST /api/internal/images/search`) — find
  library images by label and get print-resolution originals, with licensing
  flags so sellable printables can exclude non-commercial artwork.
- Internal API board search (`GET /api/internal/boards/search`) and tag
  discovery (`GET /api/internal/boards/tags`) — filter admin boards by tag,
  name or description, published or not.
- `rake images:license_audit` — read-only report of the image library's
  license breakdown.
```

- [ ] **Step 8: Commit**

```bash
git add README.md CLAUDE.md CHANGELOG.md
git add -f .claude-notes/internal-api.md
git commit -m "docs: document internal API search endpoints

Adds an endpoint index to the README internal API section, documents all
four search endpoints with curl examples, and calls out the two easy
mistakes: src vs original_url, and unpublished-by-default board search.

New .claude-notes/internal-api.md spoke covers the auth model, the CDN
download path and the licensing rule.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Full verification

**Files:** none — verification only.

- [ ] **Step 1: Run every spec touched or added by this work**

```bash
bundle exec rspec \
  spec/services/images/commercial_license_spec.rb \
  spec/services/images/label_search_spec.rb \
  spec/services/boards/admin_search_spec.rb \
  spec/requests/api/internal/ \
  spec/lib/tasks/image_licenses_rake_spec.rb
```

Expected: all examples pass, zero failures. **Do not proceed while anything is red** — record the actual output rather than asserting success.

- [ ] **Step 2: Confirm the existing internal endpoints still behave**

The whole `spec/requests/api/internal/` directory ran in Step 1. Confirm
`boards_spec.rb`, `images_spec.rb`, `board_pdf_export_spec.rb`,
`marketing_assets_spec.rb` and `profiles_spec.rb` all appear in the output and
pass — these are the regression surface for routing changes.

- [ ] **Step 3: Verify the routes resolve as intended**

```bash
bin/rails routes | grep -E "internal.*(search|tags)"
```

Expected: four rows —
`GET /api/internal/images/search`, `POST /api/internal/images/search`,
`GET /api/internal/boards/search`, `GET /api/internal/boards/tags`.

Confirm none of them resolve to a `#show` action — that would mean the route
landed in a `member` block and is being shadowed.

- [ ] **Step 4: Smoke-test against the dev server**

Start the server (`bin/dev`) in one shell, then in another:

```bash
export INTERNAL_API_KEY=$(grep INTERNAL_API_KEY config/application.yml | cut -d' ' -f2)
curl -sG http://localhost:4000/api/internal/images/search \
  -H "Authorization: Bearer $INTERNAL_API_KEY" \
  --data-urlencode "q=apple" | head -40
```

Expected: a JSON body with `results`, each carrying a populated `original_url`.
Fetch one `original_url` with `curl -I` and confirm it returns `200` — that
proves the end-to-end download path the printables pipeline depends on.

If `config/application.yml` has no `INTERNAL_API_KEY`, add one locally
(`bin/rails runner 'puts SecureRandom.hex(32)'`) — do not commit it.

- [ ] **Step 5: Commit any fixes**

If Steps 1–4 surfaced problems, fix them and commit:

```bash
git add -A
git commit -m "fix: <what was actually broken>

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

If everything passed, there is nothing to commit — say so explicitly rather
than creating an empty commit.

---

## Definition of done

- All four endpoints respond correctly and are covered by request specs
- `Images::CommercialLicense` is unit-tested against the **real** license
  strings measured in the library, and fails closed
- `rake images:license_audit` runs clean against the dev DB
- README's internal API section has an endpoint index and documents all four
  endpoints, including both footgun callouts
- `.claude-notes/internal-api.md` exists and is force-added
- `CLAUDE.md` subsystem map and `CHANGELOG.md` updated
- Full internal-API request spec directory green
