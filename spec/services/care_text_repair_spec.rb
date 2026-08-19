require "rails_helper"

# Rows saved before CareText landed hold HTML-escaped care text — an ampersand
# a parent typed was persisted as "&amp;" and published as that literal string
# on the public MySpeak page and in the printed care plan. These specs pin the
# repair: it has to fix escaping, refuse to write live markup back into the
# column, and be safe to re-run.
#
# The stored blobs here are written with update_column, deliberately: a normal
# save runs sanitize_care_settings, which would clean them on the way in and
# leave nothing to repair.
RSpec.describe CareTextRepair do
  let(:user) { FactoryBot.create(:user) }
  let(:child) { FactoryBot.create(:child_account, user: user, owner: user) }
  let(:profile) do
    Profile.create!(profileable: child, username: "care-repair", slug: "care-repair")
  end

  def store(sections)
    profile.update_column(:settings, { "care" => { "sections" => sections } })
    profile.reload
  end

  def repaired(sections)
    described_class.apply(store(sections).settings["care"])
  end

  describe ".apply" do
    it "unescapes a short_text value on a built-in section" do
      out = repaired(
        "sensory" => { "values" => { "calming" => "Loves hugs &amp; quiet spaces" } },
      )

      expect(out.dig("sections", "sensory", "values", "calming"))
        .to eq("Loves hugs & quiet spaces")
    end

    it "unescapes custom item labels and values" do
      out = repaired(
        "meals" => {
          "items" => [{ "label" => "Cups &amp; lids", "value" => "Green &amp; blue only" }],
        },
      )

      expect(out.dig("sections", "meals", "items", 0))
        .to eq("label" => "Cups & lids", "value" => "Green & blue only")
    end

    it "unescapes a custom section title" do
      out = repaired(
        "c_7f3a91" => {
          "custom" => true,
          "title" => "Snacks &amp; drinks",
          "items" => [{ "label" => "Cup", "value" => "Green" }],
        },
      )

      expect(out.dig("sections", "c_7f3a91", "title")).to eq("Snacks & drinks")
    end

    # The reason this reuses CareText rather than a bare CGI.unescapeHTML: a
    # legacy row can hold an escaped tag, and unescaping that alone would write
    # live markup back into the column.
    it "strips markup the unescape reveals instead of storing it" do
      out = repaired(
        "sensory" => {
          "values" => { "calming" => "&lt;script&gt;alert(1)&lt;/script&gt;quiet" },
        },
      )

      stored = out.dig("sections", "sensory", "values", "calming")
      expect(stored).not_to include("<script")
      expect(stored).not_to include("&lt;")
    end

    it "returns nil when nothing needs repairing" do
      expect(repaired("sensory" => { "values" => { "calming" => "hugs & quiet" } })).to be_nil
    end

    it "is idempotent — a second pass finds nothing" do
      sections = { "sensory" => { "values" => { "calming" => "hugs &amp; quiet" } } }
      first = repaired(sections)

      expect(described_class.apply(first)).to be_nil
    end

    it "leaves select values alone" do
      out = repaired(
        "communication" => {
          "values" => { "methods" => %w[aac_device gestures] },
          "items" => [{ "label" => "Cues", "value" => "Wait &amp; watch" }],
        },
      )

      expect(out.dig("sections", "communication", "values", "methods"))
        .to eq(%w[aac_device gestures])
    end

    it "ignores a blob with no sections" do
      expect(described_class.apply("order" => %w[sensory])).to be_nil
    end
  end

  describe ".hits_for" do
    it "names the fields a repair would change" do
      store(
        "sensory" => { "values" => { "calming" => "hugs &amp; quiet" } },
        "meals" => { "items" => [{ "label" => "Cups &amp; lids", "value" => "Green" }] },
      )

      expect(described_class.hits_for(profile))
        .to contain_exactly("sensory.calming", "meals.items[0]")
    end

    it "is empty for a clean profile" do
      store("sensory" => { "values" => { "calming" => "hugs & quiet" } })

      expect(described_class.hits_for(profile)).to be_empty
    end

    it "is empty for a profile with no care settings" do
      profile.update_column(:settings, {})

      expect(described_class.hits_for(profile)).to be_empty
    end
  end
end
