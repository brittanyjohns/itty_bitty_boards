# == Schema Information
#
# Table name: profiles
#
#  id               :bigint           not null, primary key
#  profileable_type :string
#  profileable_id   :bigint
#  username         :string
#  slug             :string
#  bio              :text
#  intro            :string
#  settings         :jsonb
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  placeholder      :boolean          default(FALSE)
#  claim_token      :string
#  claimed_at       :datetime
#  sku              :string
#  profile_kind     :string           default("safety"), not null
#  allow_discovery  :boolean          default(FALSE), not null
#  slug_changed_at  :datetime
#
require "rails_helper"

RSpec.describe Profile, type: :model do
  let(:user) { FactoryBot.create(:user) }
  let(:child) { FactoryBot.create(:child_account, user: user, owner: user) }

  def build_profile(slug:, **overrides)
    Profile.new(
      profileable: child,
      username: overrides.fetch(:username, slug),
      slug: slug,
      bio: "bio",
      intro: "intro",
    )
  end

  # bio and intro are PUBLIC — /my/:slug prints the bio as About Me and speaks
  # the intro aloud — so seeding them published app instructions to visitors in
  # the communicator's own voice.
  describe "bio and intro defaults" do
    it "leaves both blank on create rather than seeding instructional copy" do
      profile = Profile.create!(profileable: child, username: "quiet-fox", slug: "quiet-fox")

      expect(profile.bio).to be_blank
      expect(profile.intro).to be_blank
    end

    it "keeps what the owner actually wrote" do
      profile = Profile.create!(
        profileable: child,
        username: "loud-fox",
        slug: "loud-fox",
        bio: "I love trains.",
        intro: "Hi, I'm Sky.",
      )

      expect(profile.bio).to eq("I love trains.")
      expect(profile.intro).to eq("Hi, I'm Sky.")
    end

    it "does not seed a profile built for a user" do
      profile = Profile.create_for_user(user, "pat-smith")

      expect(profile.bio).to be_blank
      expect(profile.intro).to be_blank
    end

    it "does not seed a generated placeholder" do
      Profile.create_placeholders(1)
      placeholder = Profile.where(placeholder: true).order(:created_at).last

      # claim! keeps whatever is stored, so anything seeded here would follow
      # the profile onto a real, claimed MySpeak page.
      expect(placeholder.bio).to be_blank
      expect(placeholder.intro).to be_blank
    end

    it "does not seed a profile generated from a username" do
      profile = Profile.generate_with_username("sky-jones")

      expect(profile.bio).to be_blank
      expect(profile.intro).to be_blank
    end
  end

  describe ".seeded_text?" do
    it "recognizes copy this app used to write into bio and intro" do
      expect(Profile.seeded_text?(Profile::SEEDED_TEXT.first)).to be(true)
    end

    it "ignores surrounding whitespace" do
      expect(Profile.seeded_text?("  #{Profile::SEEDED_TEXT.first}\n")).to be(true)
    end

    it "is false for blank input" do
      expect(Profile.seeded_text?(nil)).to be(false)
      expect(Profile.seeded_text?("")).to be(false)
    end

    # Whole-string match, never a substring: a real bio that quotes the phrase
    # belongs to whoever wrote it.
    it "does not match a real bio that merely quotes the copy" do
      quoting = "The app told me to \"#{Profile::SEEDED_TEXT.first}\" so here goes: I love trains."

      expect(Profile.seeded_text?(quoting)).to be(false)
    end
  end

  describe "slug format validation (on change)" do
    it "accepts a kebab-case 3-40 char slug" do
      profile = build_profile(slug: "river-stone-42")
      expect(profile).to be_valid
    end

    it "rejects a slug with uppercase letters" do
      profile = build_profile(slug: "River-Stone")
      expect(profile).not_to be_valid
      expect(profile.errors[:slug].join).to match(/lowercase/)
    end

    it "rejects a slug with underscores" do
      profile = build_profile(slug: "river_stone")
      expect(profile).not_to be_valid
    end

    it "rejects a slug shorter than 3 chars" do
      profile = build_profile(slug: "ab")
      expect(profile).not_to be_valid
    end

    it "rejects a slug longer than 40 chars" do
      profile = build_profile(slug: "a" + "b" * 40)
      expect(profile).not_to be_valid
    end

    it "rejects leading or trailing hyphen" do
      expect(build_profile(slug: "-river")).not_to be_valid
      expect(build_profile(slug: "river-")).not_to be_valid
    end

    it "leaves legacy rows alone when unrelated fields are updated" do
      # Bypass validations to seed a legacy slug, then update an unrelated field.
      profile = build_profile(slug: "ok-slug").tap { |p| p.save!(validate: false) }
      profile.update_columns(slug: "Legacy_Slug")
      profile.reload
      profile.bio = "edited"
      expect(profile).to be_valid
    end
  end

  describe "reserved slug rejection (on change)" do
    %w[admin api myspeak speakanyway m u v p c onboarding].each do |reserved|
      it "rejects #{reserved.inspect}" do
        profile = build_profile(slug: reserved)
        expect(profile).not_to be_valid
        expect(profile.errors[:slug].join).to match(/reserved/)
      end
    end

    it "rejects an all-numeric slug" do
      profile = build_profile(slug: "1234567")
      expect(profile).not_to be_valid
      expect(profile.errors[:slug].join).to match(/all numbers/)
    end
  end

  describe "#slug_editable?" do
    let(:profile) do
      build_profile(slug: "river-stone").tap(&:save!)
    end

    it "is true when slug_changed_at is nil" do
      profile.update_columns(slug_changed_at: nil)
      expect(profile.slug_editable?).to be(true)
    end

    it "is false within 7 days of the last change" do
      profile.update_columns(slug_changed_at: 1.day.ago)
      expect(profile.slug_editable?).to be(false)
    end

    it "is true once 7 days have passed" do
      profile.update_columns(slug_changed_at: 8.days.ago)
      expect(profile.slug_editable?).to be(true)
    end
  end

  describe "#slug_editable_at" do
    let(:profile) do
      build_profile(slug: "river-stone").tap(&:save!)
    end

    it "is nil when slug_changed_at is nil" do
      profile.update_columns(slug_changed_at: nil)
      expect(profile.slug_editable_at).to be_nil
    end

    it "is 7 days after the last change" do
      changed_at = 2.days.ago.beginning_of_minute
      profile.update_columns(slug_changed_at: changed_at)
      expect(profile.slug_editable_at).to be_within(1.second).of(changed_at + 7.days)
    end
  end

  describe "touch_slug_changed_at callback" do
    it "does NOT set slug_changed_at on initial create" do
      profile = build_profile(slug: "river-stone")
      expect { profile.save! }.not_to change { profile.slug_changed_at }
      expect(profile.slug_changed_at).to be_nil
    end

    it "sets slug_changed_at when slug is changed on an existing record" do
      profile = build_profile(slug: "river-stone").tap(&:save!)
      profile.slug = "new-slug"
      expect { profile.save! }.to change { profile.slug_changed_at }.from(nil)
    end

    it "does NOT update slug_changed_at when an unrelated field changes" do
      profile = build_profile(slug: "river-stone").tap(&:save!)
      profile.bio = "edited"
      expect { profile.save! }.not_to change { profile.slug_changed_at }
    end
  end

  describe ".slug_available?" do
    it "is true for a fresh slug" do
      expect(Profile.slug_available?("totally-new")).to be(true)
    end

    it "is false when another Profile has the slug" do
      build_profile(slug: "river-stone").save!
      expect(Profile.slug_available?("river-stone")).to be(false)
    end

    it "is false when another Profile uses the value as its username" do
      Profile.new(
        profileable: child,
        username: "claimed-name",
        slug: "different-slug",
      ).save!(validate: false)
      expect(Profile.slug_available?("claimed-name")).to be(false)
    end

    it "is false when a ChildAccount uses the value as its login username" do
      FactoryBot.create(:child_account, user: user, owner: user, username: "logged-in-user")
      expect(Profile.slug_available?("logged-in-user")).to be(false)
    end

    it "excludes the profile's own id when except_id is supplied" do
      profile = build_profile(slug: "river-stone").tap(&:save!)
      expect(Profile.slug_available?("river-stone", except_id: profile.id)).to be(true)
    end
  end

  describe ".slug_unavailable_reason" do
    it "returns :format for blank / bad-shape input" do
      expect(Profile.slug_unavailable_reason("")).to eq(:format)
      expect(Profile.slug_unavailable_reason("Bad_Slug")).to eq(:format)
    end

    it "returns :reserved for the reserved list" do
      expect(Profile.slug_unavailable_reason("admin")).to eq(:reserved)
    end

    it "returns :reserved for all-numeric" do
      expect(Profile.slug_unavailable_reason("1234")).to eq(:reserved)
    end

    it "returns :taken when the slug exists elsewhere" do
      build_profile(slug: "river-stone").save!
      expect(Profile.slug_unavailable_reason("river-stone")).to eq(:taken)
    end

    it "returns nil for a fresh, well-formed slug" do
      expect(Profile.slug_unavailable_reason("river-stone")).to be_nil
    end
  end

  # The public views back unauthenticated profile pages. They must not leak
  # the communicator's full api_view (parent email, passcode, claim tokens)
  # nor a raw email field.
  describe "#safety_view" do
    let(:profile) { build_profile(slug: "safe-page").tap(&:save!) }

    it "omits communicator_account and email" do
      view = profile.safety_view
      expect(view).not_to have_key(:communicator_account)
      expect(view).not_to have_key(:email)
    end

    it "exposes a sanitized theme in the page-safe settings" do
      profile.update!(settings: { "theme" => { "preset" => "ocean", "accent" => "#0EA5E9" } })
      expect(profile.safety_view[:settings]["theme"]).to eq("preset" => "ocean", "accent" => "#0EA5E9")
    end

    it "never exposes sensitive safety keys in the page-safe settings" do
      profile.update!(settings: { "allergies" => "peanuts", "ice_contact_1" => "Mom" })
      expect(profile.safety_view[:settings]).not_to have_key("allergies")
      expect(profile.safety_view[:settings]).not_to have_key("ice_contact_1")
    end
  end

  describe "care sections" do
    let(:profile) { build_profile(slug: "care-page").tap(&:save!) }

    # `order` is positional, not a keyword: a bare `"key" => value` at the call
    # site binds to keyword params in Ruby 3, which would swallow the sections.
    def care(sections, order = nil)
      blob = { "sections" => sections }
      blob["order"] = order if order
      profile.update!(settings: { "care" => blob })
      profile.reload.settings["care"]
    end

    describe "sanitize_care_settings callback" do
      it "keeps registry-valid values on a built-in section" do
        result = care(
          "communication" => {
            "enabled" => true,
            "values" => {
              "methods" => %w[aac_device gestures],
              "what_helps" => %w[wait_and_pause offer_choices],
            },
          },
        )

        expect(result["sections"]["communication"]).to eq(
          "enabled" => true,
          "values" => {
            "methods" => %w[aac_device gestures],
            "what_helps" => %w[wait_and_pause offer_choices],
          },
        )
      end

      # Detail lines on a BUILT-IN section. The chips answer "which of these
      # applies"; the specific, provisional thing a parent needs to pass on
      # ("Bus: back left seat, by the window") doesn't compress into a chip.
      # They are the only free-text surface a built-in section has, which is
      # what lets the option lists stay short.
      describe "detail lines on a built-in section" do
        it "keeps label/value rows alongside the preset values" do
          result = care(
            "meals" => {
              "values" => { "eating" => %w[food_cut_up] },
              "items" => [
                { "label" => "Drinks", "value" => "Green straw cup only" },
                { "label" => "Pieces", "value" => "Cut big pieces up" },
              ],
            },
          )

          expect(result["sections"]["meals"]["values"]).to eq("eating" => %w[food_cut_up])
          expect(result["sections"]["meals"]["items"]).to eq(
            [
              { "label" => "Drinks", "value" => "Green straw cup only" },
              { "label" => "Pieces", "value" => "Cut big pieces up" },
            ],
          )
        end

        it "keeps a section that has only lines and no preset values" do
          result = care(
            "meals" => { "items" => [{ "label" => "Temperature", "value" => "Won't eat cold food" }] },
          )

          expect(result["sections"]["meals"]["values"]).to eq({})
          expect(result["sections"]["meals"]["items"].length).to eq(1)
        end

        it "still drops a section with neither values nor lines" do
          result = care("meals" => { "items" => [{ "label" => " ", "value" => "" }] })
          expect(result).to be_nil
        end

        it "omits the key entirely rather than storing an empty list" do
          result = care("meals" => { "values" => { "eating" => %w[food_cut_up] } })
          expect(result["sections"]["meals"]).not_to have_key("items")
        end

        it "applies the same caps and stripping as a custom section" do
          result = care(
            "meals" => {
              "items" => Array.new(Profile::MAX_CARE_CUSTOM_ITEMS + 3) do
                { "label" => "l" * (Profile::CARE_ITEM_LABEL_MAX + 5),
                  "value" => "<b>v</b>" + "v" * (Profile::CARE_ITEM_VALUE_MAX + 5) }
              end,
            },
          )

          items = result["sections"]["meals"]["items"]
          expect(items.length).to eq(Profile::MAX_CARE_CUSTOM_ITEMS)
          expect(items.first["label"].length).to eq(Profile::CARE_ITEM_LABEL_MAX)
          expect(items.first["value"]).not_to include("<b>")
          expect(items.first["value"].length).to eq(Profile::CARE_ITEM_VALUE_MAX)
        end

        it "drops rows that are neither labelled nor filled, keeping the rest" do
          result = care(
            "meals" => {
              "values" => { "eating" => %w[food_cut_up] },
              "items" => [
                { "label" => "", "value" => "" },
                { "label" => "Pieces", "value" => "" },
                { "label" => "", "value" => "No straws" },
                "not a hash",
              ],
            },
          )

          expect(result["sections"]["meals"]["items"]).to eq(
            [
              { "label" => "Pieces", "value" => "" },
              { "label" => "", "value" => "No straws" },
            ],
          )
        end

        it "leaves a section stored before lines existed untouched" do
          # Backwards compatibility: rows written by the previous release have
          # no "items" key at all and must round-trip unchanged.
          result = care("meals" => { "enabled" => true, "values" => { "eating" => %w[tube_fed] } })
          expect(result["sections"]["meals"]).to eq(
            "enabled" => true, "values" => { "eating" => %w[tube_fed] },
          )
        end
      end

      it "drops unknown sections, unknown fields, and out-of-registry options" do
        result = care(
          "communication" => {
            "values" => {
              "methods" => %w[aac_device not_a_method],
              "what_helps" => %w[wildly_invented],
              "sneaky_field" => "nope",
            },
          },
          "not_a_section" => { "values" => { "methods" => %w[aac_device] } },
        )

        expect(result["sections"].keys).to eq(%w[communication])
        expect(result["sections"]["communication"]["values"]).to eq("methods" => %w[aac_device])
      end

      it "drops a built-in section whose every value was invalid" do
        profile.update!(settings: { "care" => { "sections" => {
          "meals" => { "values" => { "eating" => %w[invented] } },
        } } })

        expect(profile.reload.settings).not_to have_key("care")
      end

      it "strips markup from free text" do
        result = care(
          "meals" => { "values" => { "preferences" => "<script>alert(1)</script>Likes <b>crunchy</b> food" } },
        )

        expect(result["sections"]["meals"]["values"]["preferences"]).to eq("alert(1)Likes crunchy food")
      end

      # strip_tags escapes entities on OUTPUT, and the cleaner runs in a
      # before_save — so a single pass persisted "hugs &amp; quiet spaces" and
      # published that literal text to the public page and the printed care
      # plan. Both consumers escape on output, so storing the raw character is
      # both correct and safe.
      describe "entities in free text" do
        it "stores a typed ampersand as a plain character" do
          result = care(
            "sensory" => { "values" => { "calming" => "Loves hugs & quiet spaces" } },
          )

          expect(result["sections"]["sensory"]["values"]["calming"])
            .to eq("Loves hugs & quiet spaces")
        end

        it "leaves angle brackets and quotes unescaped too" do
          result = care(
            "meals" => { "values" => { "preferences" => %(Cut pieces < 1" & "no crusts") } },
          )

          expect(result["sections"]["meals"]["values"]["preferences"])
            .to eq(%(Cut pieces < 1" & "no crusts"))
        end

        # The reason the cleaner strips a second time. Unescaping is what turns
        # this input into live markup, so it has to be stripped AFTER the
        # unescape, not before.
        it "does not resurrect a tag that arrived escaped" do
          result = care(
            "sensory" => { "values" => { "calming" => "&lt;script&gt;alert(1)&lt;/script&gt;quiet" } },
          )

          stored = result["sections"]["sensory"]["values"]["calming"]
          expect(stored).not_to include("<script")
          expect(stored).not_to include("&lt;")
        end

        it "is stable across re-saves rather than compounding" do
          care("sensory" => { "values" => { "calming" => "hugs & quiet" } })

          profile.update!(updated_at: Time.current)

          expect(profile.reload.settings.dig("care", "sections", "sensory", "values", "calming"))
            .to eq("hugs & quiet")
        end

        it "applies to custom item labels and values, and custom titles" do
          result = care(
            "c_7f3a91" => {
              "custom" => true,
              "title" => "Snacks & drinks",
              "items" => [{ "label" => "Cups & straws", "value" => "Green cup & lid only" }],
            },
          )

          section = result["sections"]["c_7f3a91"]
          expect(section["title"]).to eq("Snacks & drinks")
          expect(section["items"].first).to eq(
            "label" => "Cups & straws", "value" => "Green cup & lid only",
          )
        end

        it "applies to detail lines on a built-in section" do
          result = care(
            "meals" => { "items" => [{ "label" => "Cups & lids", "value" => "Green & blue only" }] },
          )

          expect(result["sections"]["meals"]["items"].first).to eq(
            "label" => "Cups & lids", "value" => "Green & blue only",
          )
        end
      end

      it "truncates over-long free text and caps multi-select length" do
        result = care(
          "meals" => {
            "values" => {
              "preferences" => "a" * 500,
              "equipment" => Profile::CARE_SECTIONS["meals"][:fields]
                               .find { |f| f[:key] == "equipment" }[:options],
            },
          },
        )

        values = result["sections"]["meals"]["values"]
        expect(values["preferences"].length).to eq(Profile::CARE_SHORT_TEXT_MAX)
        expect(values["equipment"].length).to be <= Profile::MAX_CARE_MULTI_SELECT
      end

      it "accepts a well-formed custom section" do
        result = care(
          "c_7f3a91" => {
            "custom" => true,
            "title" => "Bedtime",
            "items" => [{ "label" => "Lights out", "value" => "7:30, door left open" }],
          },
        )

        expect(result["sections"]["c_7f3a91"]).to eq(
          "enabled" => true,
          "custom" => true,
          "title" => "Bedtime",
          "items" => [{ "label" => "Lights out", "value" => "7:30, door left open" }],
        )
      end

      it "rejects a custom section key that doesn't match the generated format" do
        profile.update!(settings: { "care" => { "sections" => {
          "c_NOTHEX" => { "title" => "Nope", "items" => [{ "label" => "a", "value" => "b" }] },
          "../../etc" => { "title" => "Nope", "items" => [{ "label" => "a", "value" => "b" }] },
        } } })

        expect(profile.reload.settings).not_to have_key("care")
      end

      it "caps the number of custom sections, keeping the parent's ordering" do
        keys = (1..Profile::MAX_CUSTOM_CARE_SECTIONS + 2).map { |i| format("c_%06x", i) }
        sections = keys.index_with do |key|
          { "title" => key, "items" => [{ "label" => "l", "value" => "v" }] }
        end

        result = care(sections, keys)

        expect(result["sections"].keys).to eq(keys.first(Profile::MAX_CUSTOM_CARE_SECTIONS))
      end

      it "caps the number of items in a custom section" do
        items = (1..Profile::MAX_CARE_CUSTOM_ITEMS + 3).map { |i| { "label" => "l#{i}", "value" => "v" } }
        result = care("c_7f3a91" => { "title" => "Bedtime", "items" => items })

        expect(result["sections"]["c_7f3a91"]["items"].length).to eq(Profile::MAX_CARE_CUSTOM_ITEMS)
      end

      it "drops a custom section with no title or no usable items" do
        profile.update!(settings: { "care" => { "sections" => {
          "c_000001" => { "title" => "", "items" => [{ "label" => "l", "value" => "v" }] },
          "c_000002" => { "title" => "Empty", "items" => [{ "label" => "", "value" => "" }] },
        } } })

        expect(profile.reload.settings).not_to have_key("care")
      end

      it "prunes order to surviving sections and appends any that were missing" do
        result = care(
          {
            "communication" => { "values" => { "what_helps" => %w[wait_and_pause] } },
            "meals" => { "values" => { "eating" => %w[food_cut_up] } },
          },
          %w[meals gone_section],
        )

        expect(result["order"]).to eq(%w[meals communication])
      end

      it "clears the key entirely when care is not a hash" do
        profile.update!(settings: { "care" => "nope" })
        expect(profile.reload.settings).not_to have_key("care")
      end
    end

    describe "#has_care_info?" do
      it "is false with no care data" do
        expect(profile.has_care_info?).to eq(false)
      end

      it "is true once a section is filled in" do
        care("communication" => { "values" => { "what_helps" => %w[wait_and_pause] } })
        expect(profile.has_care_info?).to eq(true)
      end

      it "is false when every section is disabled" do
        care("communication" => { "enabled" => false, "values" => { "what_helps" => %w[wait_and_pause] } })
        expect(profile.has_care_info?).to eq(false)
      end
    end

    describe "#safety_view / #care_details_view" do
      before { care("communication" => { "values" => { "what_helps" => %w[wait_and_pause] } }) }

      it "advertises care on the open page without shipping the data" do
        view = profile.safety_view
        expect(view[:has_care_info]).to eq(true)
        expect(view[:settings]).not_to have_key("care")
      end

      it "returns the care blob only from the gated view" do
        expect(profile.care_details_view[:settings]["care"]["sections"]).to have_key("communication")
      end
    end
  end

  describe "sanitize_theme_settings callback" do
    let(:profile) { build_profile(slug: "theme-page").tap(&:save!) }

    it "keeps valid hex and slug values" do
      profile.update!(settings: {
        "theme" => {
          "preset" => "sunset",
          "bg_style" => "gradient",
          "accent" => "#0EA5E9",
          "bg_color" => "#F0F9FF",
          "border_color" => "#BAE6FD",
          "text_color" => "#0C4A6E",
        },
      })
      expect(profile.reload.settings["theme"]).to eq(
        "accent" => "#0EA5E9",
        "bg_color" => "#F0F9FF",
        "border_color" => "#BAE6FD",
        "text_color" => "#0C4A6E",
        "preset" => "sunset",
        "bg_style" => "gradient",
      )
    end

    it "drops invalid hex values (named color, short hex)" do
      profile.update!(settings: { "theme" => { "accent" => "red", "bg_color" => "#fff" } })
      expect(profile.reload.settings).not_to have_key("theme")
    end

    it "drops a CSS-injection attempt in a hex field" do
      profile.update!(settings: { "theme" => { "accent" => "#fff; background:url(javascript:alert(1))" } })
      expect(profile.reload.settings).not_to have_key("theme")
    end

    it "drops slug values that aren't simple slugs" do
      profile.update!(settings: { "theme" => { "preset" => "Ocean Blue!", "accent" => "#0EA5E9" } })
      theme = profile.reload.settings["theme"]
      expect(theme).to eq("accent" => "#0EA5E9")
      expect(theme).not_to have_key("preset")
    end

    it "strips unknown keys (whitelist, not blocklist)" do
      profile.update!(settings: { "theme" => { "accent" => "#0EA5E9", "evil" => "boom", "font" => "Comic Sans" } })
      expect(profile.reload.settings["theme"]).to eq("accent" => "#0EA5E9")
    end

    it "deletes the key when theme is not a hash" do
      profile.update!(settings: { "theme" => "hacker" })
      expect(profile.reload.settings).not_to have_key("theme")
    end

    it "deletes the key when every theme value is invalid" do
      profile.update!(settings: { "theme" => { "accent" => "nope", "preset" => "" } })
      expect(profile.reload.settings).not_to have_key("theme")
    end

    it "leaves non-theme settings untouched" do
      profile.update!(settings: { "pronouns" => "she/her", "theme" => { "accent" => "#0EA5E9" } })
      settings = profile.reload.settings
      expect(settings["pronouns"]).to eq("she/her")
      expect(settings["theme"]).to eq("accent" => "#0EA5E9")
    end
  end

  describe "#public_page_view" do
    let(:profile) do
      build_profile(slug: "pro-page").tap do |p|
        p.profile_kind = "public_page"
        p.save!
      end
    end

    it "omits the raw email field" do
      expect(profile.public_page_view).not_to have_key(:email)
    end

    it "exposes a ChildAccount communicator_account via the sanitized public_api_view" do
      view = profile.public_page_view
      expect(view[:communicator_account]).to eq(child.public_api_view)
      expect(view[:communicator_account].keys).to contain_exactly(:id, :name, :avatar_url, :voice, :boards)
    end

    it "does not leak the communicator's parent email or passcode" do
      account = profile.public_page_view[:communicator_account]
      expect(account).not_to have_key(:parent_email)
      expect(account).not_to have_key(:passcode)
    end
  end

  describe ".generate_random_slug" do
    it "returns an 's-' prefix plus 6 unambiguous alphanumeric chars" do
      slug = Profile.generate_random_slug
      expect(slug).to match(/\As-[a-z0-9]{6}\z/)
    end

    it "never includes ambiguous characters (0, o, 1, l, i)" do
      200.times do
        body = Profile.generate_random_slug.delete_prefix("s-")
        expect(body).not_to match(/[0o1li]/)
      end
    end

    it "retries until it finds a slug not already used as slug or legacy_slug" do
      # Force the first candidate to collide, the second to be free.
      allow(Profile).to receive(:exists?).and_return(true, true, false, false)
      expect(Profile.generate_random_slug).to match(/\As-[a-z0-9]{6}\z/)
    end
  end

  describe "#ensure_slug (random safety slugs)" do
    it "assigns a random slug + slug_type 'random' to a safety profile with no slug" do
      profile = Profile.new(profileable: child, username: "emma-jones")
      profile.save!
      expect(profile.slug).to match(/\As-[a-z0-9]{6}\z/)
      expect(profile.slug_type).to eq("random")
    end

    it "does not overwrite an explicitly provided slug" do
      profile = build_profile(slug: "emma-jones").tap(&:save!)
      expect(profile.slug).to eq("emma-jones")
      expect(profile.slug_type).to eq("legacy")
    end

    it "derives a readable slug from the username for a non-safety profile" do
      profile = Profile.new(
        profileable: user,
        profile_kind: "public_page",
        username: "Pat Smith",
      )
      profile.save!
      expect(profile.slug).to eq("pat-smith")
      expect(profile.slug_type).to eq("legacy")
    end
  end

  describe "#slug_editable? with a random slug" do
    it "is false even when slug_changed_at is blank" do
      profile = Profile.new(profileable: child, username: "emma").tap(&:save!)
      expect(profile.slug_type).to eq("random")
      expect(profile.slug_changed_at).to be_nil
      expect(profile.slug_editable?).to be(false)
    end
  end

  describe ".slug_available? with legacy_slug" do
    it "is false when the value matches an existing legacy_slug" do
      profile = Profile.new(profileable: child, username: "emma").tap(&:save!)
      profile.update_columns(legacy_slug: "emma-jones")
      expect(Profile.slug_available?("emma-jones")).to be(false)
    end
  end

  # The public MySpeak page falls back to synthesizing on EVERY tap when a clip
  # is missing (a multi-second wait each time), so "which fields get a clip" is
  # the difference between an instant button and a dead-feeling one.
  describe "#update_audio" do
    let(:profile) { Profile.new(profileable: child, username: "emma").tap(&:save!) }

    before do
      allow(VoiceService).to receive(:synthesize_speech).and_return(StringIO.new("mp3-bytes"))
    end

    it "generates bio audio when there is a bio but no intro" do
      profile.update_columns(intro: nil, bio: "I love trains.")

      profile.update_audio(:bio)

      expect(VoiceService).to have_received(:synthesize_speech)
        .with(hash_including(text: "I love trains."))
      expect(profile.reload.bio_audio).to be_attached
    end

    it "generates intro audio when there is an intro but no bio" do
      profile.update_columns(intro: "Hi, I'm Emma.", bio: nil)

      profile.update_audio(:intro)

      expect(VoiceService).to have_received(:synthesize_speech)
        .with(hash_including(text: "Hi, I'm Emma."))
      expect(profile.reload.intro_audio).to be_attached
    end

    it "does not call the synthesizer for a blank field" do
      profile.update_columns(intro: "Hi, I'm Emma.", bio: "")

      profile.update_audio(:bio)

      expect(VoiceService).not_to have_received(:synthesize_speech)
      expect(profile.reload.bio_audio).not_to be_attached
    end

    it "ignores an unknown audio type" do
      profile.update_columns(intro: "Hi, I'm Emma.", bio: "I love trains.")

      expect(profile.update_audio(:nickname)).to be_nil
      expect(VoiceService).not_to have_received(:synthesize_speech)
    end
  end

  # Both lists are serialized straight into an UNAUTHENTICATED payload, while
  # the board behind each card is gated on Board#viewable_by? — which refuses
  # an anonymous visitor an unpublished board. Selecting on `favorite` alone
  # served a card for a private board that 404'd on tap.
  describe "published filtering on the public board lists" do
    let(:owner) { create(:user) }

    describe "#communication_boards for a communicator" do
      let(:child) { create(:child_account, user: owner, owner: owner) }
      let(:profile) do
        Profile.new(profileable: child, username: "sky-cb", slug: "sky-cb").tap(&:save!)
      end

      it "includes a favorited published board" do
        board = create(:board, user: owner, published: true)
        create(:child_board, board: board, child_account: child, favorite: true)

        expect(profile.communication_boards.map(&:board_id)).to include(board.id)
      end

      it "excludes a favorited board that is not published" do
        board = create(:board, user: create(:user), published: false)
        create(:child_board, board: board, child_account: child, favorite: true)

        expect(profile.communication_boards.map(&:board_id)).not_to include(board.id)
      end

      it "still preloads without raising on the ChildBoard relation" do
        board = create(:board, user: owner, published: true)
        create(:child_board, board: board, child_account: child, favorite: true)

        expect { profile.communication_boards.map(&:public_card_view) }.not_to raise_error
      end
    end

    # User#favorite_boards returns Boards, not ChildBoard join rows — the two
    # branches of #communication_boards can't be collapsed, so both need cover.
    describe "#communication_boards for a user" do
      let(:profile) do
        Profile.new(profileable: owner, username: "pat-cb", slug: "pat-cb").tap(&:save!)
      end

      it "excludes an unpublished favorited board" do
        published = create(:board, user: owner, favorite: true, published: true)
        private_board = create(:board, user: owner, favorite: true, published: false)

        ids = profile.communication_boards.map(&:id)
        expect(ids).to include(published.id)
        expect(ids).not_to include(private_board.id)
      end
    end

    describe "#user_boards" do
      let(:profile) do
        Profile.new(profileable: owner, username: "pat-ub", slug: "pat-ub").tap(&:save!)
      end

      it "excludes an unpublished board from the user's public page" do
        published = create(:board, user: owner, published: true,
                                   board_type: "board", sub_board: false)
        private_board = create(:board, user: owner, published: false,
                                       board_type: "board", sub_board: false)

        ids = profile.user_boards.map(&:id)
        expect(ids).to include(published.id)
        expect(ids).not_to include(private_board.id)
      end
    end
  end
end
