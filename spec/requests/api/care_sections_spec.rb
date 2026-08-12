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
          # OFFERED options, not the raw registry: an option that has been
          # retired is still accepted on save but must never be presented as a
          # fresh choice. See Profile::DEPRECATED_CARE_OPTIONS.
          expected = source[:options] &&
                     Profile.offered_care_options(section["key"], source)
          expect(field["options"]).to eq(expected)
        end
      end
    end

    it "omits options for a short_text field rather than sending an empty list" do
      get "/api/care_sections"
      body = JSON.parse(response.body)

      notes = body["sections"]
              .find { |s| s["key"] == "communication" }["fields"]
              .find { |f| f["key"] == "notes" }

      expect(notes["type"]).to eq("short_text")
      expect(notes).not_to have_key("options")
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

    it "never offers an option that has been retired" do
      get "/api/care_sections"
      body = JSON.parse(response.body)

      Profile::DEPRECATED_CARE_OPTIONS.each do |section_key, fields|
        served = body["sections"].find { |s| s["key"] == section_key }
        next unless served

        fields.each do |field_key, mapping|
          offered = served["fields"].find { |f| f["key"] == field_key }&.dig("options") || []
          expect(offered).not_to include(*mapping.keys)
        end
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
