require "rails_helper"

# The care registry is served so the frontend stops carrying a hand-copied
# duplicate of Profile::CARE_SECTIONS. sanitize_care_settings DROPS an option
# key it doesn't recognize rather than rejecting it, so a drifted copy deleted a
# parent's answer on their next save with no error and no 422 — which is why
# these assertions are about the payload matching the constant exactly, not
# about it matching a fixture of what the constant happened to say.
RSpec.describe "API::CareSections", type: :request do
  describe "GET /api/care_sections" do
    it "is readable without a token" do
      get "/api/care_sections"
      expect(response).to have_http_status(:ok)
    end

    it "serves every section in registry order" do
      get "/api/care_sections"
      body = JSON.parse(response.body)

      expect(body["sections"].map { |s| s["key"] }).to eq(Profile::CARE_SECTIONS.keys)
    end

    it "serves every field with its type, and its options where it has them" do
      get "/api/care_sections"
      body = JSON.parse(response.body)

      body["sections"].each do |section|
        spec = Profile::CARE_SECTIONS.fetch(section["key"])
        expect(section["fields"].map { |f| f["key"] }).to eq(spec[:fields].map { |f| f[:key] })

        section["fields"].each_with_index do |field, idx|
          source = spec[:fields][idx]
          expect(field["type"]).to eq(source[:type].to_s)
          # OFFERED, not the raw constant: a retired option stays acceptable on
          # save but must never be presented as a fresh choice.
          expected = source[:options] && Profile.offered_care_options(section["key"], source)
          expect(field["options"]).to eq(expected)
        end
      end
    end

    it "omits options for a short_text field rather than sending an empty list" do
      get "/api/care_sections"
      body = JSON.parse(response.body)

      preferences = body["sections"]
                    .find { |s| s["key"] == "meals" }["fields"]
                    .find { |f| f["key"] == "preferences" }

      expect(preferences["type"]).to eq("short_text")
      expect(preferences).not_to have_key("options")
    end

    it "serves every cap the sanitizer enforces" do
      get "/api/care_sections"
      limits = JSON.parse(response.body)["limits"]

      expect(limits).to eq(
        "max_custom_sections" => Profile::MAX_CUSTOM_CARE_SECTIONS,
        "max_custom_items" => Profile::MAX_CARE_CUSTOM_ITEMS,
        "max_multi_select" => Profile::MAX_CARE_MULTI_SELECT,
        "title_max" => Profile::CARE_TITLE_MAX,
        "item_label_max" => Profile::CARE_ITEM_LABEL_MAX,
        "item_value_max" => Profile::CARE_ITEM_VALUE_MAX,
        "short_text_max" => Profile::CARE_SHORT_TEXT_MAX,
      )
    end

    describe "custom_key_format" do
      # Ruby's \A and \z are not valid in a JavaScript RegExp, so the pattern is
      # translated on the way out. A consumer that compiled Regexp#source raw
      # would throw.
      it "is a pattern JavaScript can compile" do
        get "/api/care_sections"
        pattern = JSON.parse(response.body)["custom_key_format"]

        expect(pattern).to eq("^c_[0-9a-f]{6}$")
        expect(pattern).not_to include("\\A")
        expect(pattern).not_to include("\\z")
      end

      it "accepts and rejects exactly what the Ruby constant does" do
        get "/api/care_sections"
        translated = Regexp.new(JSON.parse(response.body)["custom_key_format"])

        %w[c_abc123 c_000000 c_ffffff].each do |key|
          expect(key).to match(Profile::CARE_CUSTOM_KEY_FORMAT)
          expect(key).to match(translated)
        end

        %w[c_ABC123 c_abc12 c_abc1234 communication ../etc c_abcxyz].each do |key|
          expect(key).not_to match(Profile::CARE_CUSTOM_KEY_FORMAT)
          expect(key).not_to match(translated)
        end
      end
    end

    describe "labels" do
      it "labels every section and field" do
        get "/api/care_sections"
        body = JSON.parse(response.body)

        body["sections"].each do |section|
          expect(section["label"]).to eq(CareLabels.section(section["key"]))

          section["fields"].each do |field|
            expect(field["label"]).to eq(CareLabels.field(section["key"], field["key"]))
          end
        end
      end

      # THE non-breaking assertion. The deployed frontend reads `options` with
      # asStringList(), which returns [] for anything that isn't an array of
      # strings — so promoting options to {key:, label:} objects would empty
      # every section in the live editor. Labels must stay a sibling key.
      it "keeps options as a flat array of strings" do
        get "/api/care_sections"
        body = JSON.parse(response.body)

        options = body["sections"].flat_map { |s| s["fields"] }.filter_map { |f| f["options"] }

        expect(options).to be_present
        expect(options.flatten).to all(be_a(String))
      end

      it "omits option_labels for a short_text field, like options" do
        get "/api/care_sections"
        body = JSON.parse(response.body)

        preferences = body["sections"]
                      .find { |s| s["key"] == "meals" }["fields"]
                      .find { |f| f["key"] == "preferences" }

        expect(preferences).not_to have_key("option_labels")
      end

      # option_labels is deliberately WIDER than options: a retired option is
      # no longer offered but is still stored on real profiles, so it still has
      # to render. Stubbed because DEPRECATED_CARE_OPTIONS is empty today —
      # the first real retirement must not be the first exercise of this path.
      it "labels a retired option that options no longer offers" do
        stub_const("Profile::DEPRECATED_CARE_OPTIONS",
                   { "meals" => { "textures" => { "minced" => nil } } })

        get "/api/care_sections"
        textures = JSON.parse(response.body)["sections"]
                       .find { |s| s["key"] == "meals" }["fields"]
                       .find { |f| f["key"] == "textures" }

        expect(textures["options"]).not_to include("minced")
        expect(textures["option_labels"]).to include("minced" => "Minced")
      end

      it "serves Spanish labels when asked, and echoes the locale" do
        get "/api/care_sections", params: { locale: "es" }
        body = JSON.parse(response.body)

        sound = body["sections"]
                .find { |s| s["key"] == "sensory" }["fields"]
                .find { |f| f["key"] == "sound" }

        expect(body["locale"]).to eq("es")
        expect(sound["option_labels"]["likes_music"]).to eq("Le gusta la música")
      end

      it "falls back to the default locale for an unknown or malformed one" do
        ["kl", "", "../../etc/passwd"].each do |bogus|
          get "/api/care_sections", params: { locale: bogus }

          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)["locale"]).to eq(I18n.default_locale.to_s)
        end
      end

      # The payload varies by locale now, so a shared/proxy cache keyed on the
      # path alone would serve a Spanish registry to an English client.
      it "is not publicly cacheable" do
        get "/api/care_sections"

        expect(response.headers["Cache-Control"]).to include("private")
        expect(response.headers["Cache-Control"]).not_to include("public")
      end
    end

    # The payload's whole job is to be the thing the sanitizer will accept. If
    # these two ever disagree, the editor offers a choice that vanishes on save.
    it "offers only options sanitize_care_settings will keep" do
      get "/api/care_sections"
      body = JSON.parse(response.body)

      user = FactoryBot.create(:user)
      child = FactoryBot.create(:child_account, user: user, owner: user)
      profile = Profile.create!(profileable: child, username: "care-registry", slug: "care-registry")
      sections = body["sections"].each_with_object({}) do |section, acc|
        values = section["fields"].each_with_object({}) do |field, vals|
          case field["type"]
          when "multi_select" then vals[field["key"]] = field["options"]
          when "single_select" then vals[field["key"]] = field["options"].first
          when "short_text" then vals[field["key"]] = "a note"
          end
        end
        acc[section["key"]] = { "enabled" => true, "values" => values }
      end

      profile.update!(settings: { "care" => { "sections" => sections } })
      stored = profile.reload.settings["care"]["sections"]

      body["sections"].each do |section|
        section["fields"].each do |field|
          expected =
            case field["type"]
            when "multi_select" then field["options"].first(Profile::MAX_CARE_MULTI_SELECT)
            when "single_select" then field["options"].first
            when "short_text" then "a note"
            end
          expect(stored.dig(section["key"], "values", field["key"])).to eq(expected),
            "#{section["key"]}.#{field["key"]} was dropped by the sanitizer"
        end
      end
    end
  end
end
