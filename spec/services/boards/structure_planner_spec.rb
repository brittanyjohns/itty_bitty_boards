require "rails_helper"

RSpec.describe Boards::StructurePlanner do
  let(:user) { create(:user) }

  describe "level normalization" do
    it "accepts valid level keys" do
      %w[starter standard extended].each do |key|
        plan = described_class.new(level: key, interests: ["pizza"]).call
        expect(plan.level).to eq(key)
      end
    end

    it "maps legacy template keys to levels" do
      plan = described_class.new(level: "core-60", interests: []).call
      expect(plan.level).to eq("standard")

      plan = described_class.new(level: "core-84", interests: []).call
      expect(plan.level).to eq("extended")
    end

    it "defaults unknown keys to standard" do
      plan = described_class.new(level: "unknown", interests: []).call
      expect(plan.level).to eq("standard")
    end
  end

  describe "core_template mapping" do
    it "maps starter and standard to core-60" do
      expect(described_class.new(level: "starter", interests: []).call.core_template).to eq("core-60")
      expect(described_class.new(level: "standard", interests: []).call.core_template).to eq("core-60")
    end

    it "maps extended to core-84" do
      expect(described_class.new(level: "extended", interests: []).call.core_template).to eq("core-84")
    end
  end

  describe "fringe page planning" do
    it "includes default pages for the level even with no interests" do
      plan = described_class.new(level: "starter", interests: []).call
      names = plan.fringe_pages.map { |p| p[:name] }
      expect(names).to include("Food", "Feelings")
    end

    # Invariant: a no-interest build must be exactly the authored core grid (a
    # clean single page). That only holds if every default category is already a
    # seed page of the level's core template — a non-seed default resolves to
    # :prebuilt/:ai_generated and gets added as an extra folder that spills the
    # grid (the Core 84 "Social folder + orphaned tile" regression).
    it "keeps every level's no-interest defaults inside the core template's seed pages" do
      {
        "starter"  => "core-60",
        "standard" => "core-60",
        "extended" => "core-84",
      }.each do |level, template|
        plan = described_class.new(level: level, interests: [], include_phrases: false).call
        expect(plan.fringe_pages).to all(satisfy { |p| p[:source] == :seed_set }),
          "#{level}: no-interest defaults must all be seed pages, got " \
          "#{plan.fringe_pages.reject { |p| p[:source] == :seed_set }.map { |p| [p[:name], p[:source]] }.inspect}"

        seed_pages = described_class::SEED_SET_PAGES[template].map(&:downcase)
        default_consts = described_class.const_get("#{level.upcase}_DEFAULTS")
        expect(default_consts.map(&:downcase)).to all(be_in(seed_pages)),
          "#{level}_DEFAULTS must be a subset of #{template} seed pages"
      end
    end

    it "includes categories from interests" do
      plan = described_class.new(level: "starter", interests: ["dog", "cat"]).call
      names = plan.fringe_pages.map { |p| p[:name] }
      expect(names).to include("Animals")
    end

    it "marks seed set pages as :seed_set source" do
      plan = described_class.new(level: "standard", interests: ["pizza"]).call
      food_page = plan.fringe_pages.find { |p| p[:name] == "Food" }
      expect(food_page[:source]).to eq(:seed_set)
    end

    it "marks categories with standalone fringe templates as :prebuilt" do
      admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      template_board = create(:board, user: admin, name: "Animals", predefined: true,
                              settings: { Boards::FringeTemplates::TEMPLATE_MARKER => "animals" })

      plan = described_class.new(level: "starter", interests: ["dog"]).call
      animals_page = plan.fringe_pages.find { |p| p[:name] == "Animals" }
      expect(animals_page[:source]).to eq(:prebuilt)
    end

    it "marks categories without any pre-built source as :ai_generated" do
      plan = described_class.new(level: "starter", interests: ["xylophone_custom_niche"]).call
      ai_pages = plan.fringe_pages.select { |p| p[:source] == :ai_generated }
      expect(ai_pages).to be_empty # "xylophone_custom_niche" has no category, goes to catch-all
    end

    it "handles aliased categories (Family & People -> People in seed set)" do
      plan = described_class.new(level: "standard", interests: ["mom"]).call
      family_page = plan.fringe_pages.find { |p| p[:name] == "Family & People" }
      expect(family_page[:source]).to eq(:seed_set)
    end
  end

  describe "sparse AI page gating" do
    # "backpack" -> School (InterestCategories). In a core-60 build School is
    # neither a seed page nor a prebuilt fringe template, so the category would
    # otherwise become an :ai_generated page named after the one word.
    it "does NOT spawn an AI page for a single niche interest; routes it to catch_all" do
      plan = described_class.new(level: "standard", interests: ["backpack"]).call

      school = plan.fringe_pages.find { |p| p[:name] == "School" }
      expect(school).to be_nil
      expect(plan.fringe_pages.select { |p| p[:source] == :ai_generated }).to be_empty
      expect(plan.catch_all_interests).to include("backpack")
      expect(plan.ai_credits_needed).to eq(0)
    end

    it "DOES spawn an AI page once the niche category clears the threshold" do
      plan = described_class.new(level: "standard", interests: %w[backpack homework]).call

      school = plan.fringe_pages.find { |p| p[:name] == "School" }
      expect(school).to be_present
      expect(school[:source]).to eq(:ai_generated)
      expect(school[:interests]).to contain_exactly("backpack", "homework")
      expect(plan.catch_all_interests).not_to include("backpack", "homework")
    end
  end

  describe "page count capping" do
    it "caps starter at 6 pages" do
      many_interests = %w[dog pizza happy toilet shirt bed sing tree hi run tablet car]
      plan = described_class.new(level: "starter", interests: many_interests).call
      expect(plan.fringe_pages.size).to be <= 6
    end

    it "caps extended at 15 pages" do
      plan = described_class.new(level: "extended", interests: []).call
      expect(plan.fringe_pages.size).to be <= 15
    end

    it "prioritizes pages with interests over defaults when capping" do
      many_interests = %w[dog pizza happy toilet shirt bed sing]
      plan = described_class.new(level: "starter", interests: many_interests).call
      pages_with_interests = plan.fringe_pages.select { |p| p[:interests].any? }
      expect(pages_with_interests.size).to be >= [plan.fringe_pages.size, 4].min
    end
  end

  describe "excluded_fringe_pages" do
    it "lists seed set pages NOT included in the plan" do
      plan = described_class.new(level: "starter", interests: ["pizza"]).call
      expect(plan.excluded_fringe_pages).to be_an(Array)
      expect(plan.excluded_fringe_pages).not_to include("Food")
      # Starter only includes Food + Feelings by default, so other seed set pages are excluded
      seed_pages = Boards::StructurePlanner::SEED_SET_PAGES["core-60"]
      excluded = seed_pages - ["Food", "Feelings"]
      excluded.each do |name|
        expect(plan.excluded_fringe_pages.map(&:downcase)).to include(name.downcase)
      end
    end
  end

  describe "catch_all_interests" do
    it "routes uncategorized words to catch-all" do
      plan = described_class.new(level: "starter", interests: ["xyznotaword"]).call
      expect(plan.catch_all_interests).to include("xyznotaword")
    end

    it "routes words from categories that got capped out to catch-all" do
      many_interests = %w[dog pizza happy toilet shirt bed sing tree hi run tablet car]
      plan = described_class.new(level: "starter", interests: many_interests).call
      planned_categories = plan.fringe_pages.map { |p| p[:name] }
      all_catch = plan.catch_all_interests
      many_interests.each do |word|
        category = Boards::InterestCategories.category_for(word)
        next if category && planned_categories.include?(category)
        next if category.nil?

        expect(all_catch).to include(word) unless planned_categories.include?(category)
      end
    end
  end

  describe "AI credit calculation" do
    it "returns 0 when no AI pages are needed" do
      plan = described_class.new(level: "standard", interests: ["pizza"]).call
      expect(plan.ai_credits_needed).to eq(0)
    end

    it "returns 2 credits per AI-generated page" do
      # Create a scenario where AI generation would be needed
      # Use interests from categories that have no pre-built source
      # and aren't in any seed set
      plan = described_class.new(level: "starter", interests: ["pizza"]).call
      ai_count = plan.fringe_pages.count { |p| p[:source] == :ai_generated }
      expect(plan.ai_credits_needed).to eq(ai_count * 2)
    end
  end

  describe "credit downgrade" do
    it "moves AI-generated pages to catch-all when user lacks credits" do
      user.update_columns(plan_credits_balance: 0, topup_credits_balance: 0)
      # Create a fringe template that's NOT in seed set or standalone
      plan = described_class.new(level: "starter", interests: ["pizza"], user: user).call
      ai_pages = plan.fringe_pages.select { |p| p[:source] == :ai_generated }
      expect(ai_pages).to be_empty
    end
  end

  describe "explicit_categories" do
    it "uses explicit categories over dictionary lookup" do
      plan = described_class.new(
        level: "standard",
        interests: ["pizza"],
        explicit_categories: { "pizza" => "Play" },
      ).call

      play_page = plan.fringe_pages.find { |p| p[:name] == "Play" }
      expect(play_page[:interests]).to include("pizza")

      food_page = plan.fringe_pages.find { |p| p[:name] == "Food" }
      expect(food_page&.dig(:interests)).not_to include("pizza") if food_page
    end
  end

  describe "phrases_page planning" do
    def profile(glp_stage: nil)
      early = glp_stage.present? && glp_stage <= 2
      instance_double(CommunicatorProfile, glp_stage: glp_stage, gestalt_early?: early)
    end

    it "includes a folder-prominence Phrases page by default (no stage, no opt-out)" do
      plan = described_class.new(level: "standard", interests: []).call
      expect(plan.phrases_page).to include(include: true, prominence: :folder)
    end

    it "promotes a strip for an early-stage gestalt processor" do
      plan = described_class.new(level: "standard", profile: profile(glp_stage: 1), interests: []).call
      expect(plan.phrases_page).to include(include: true, prominence: :strip, stage: 1)
    end

    it "uses the folder for a later-stage processor" do
      plan = described_class.new(level: "standard", profile: profile(glp_stage: 5), interests: []).call
      expect(plan.phrases_page).to include(prominence: :folder, stage: 5)
    end

    it "omits the Phrases page when explicitly opted out and no stage is set" do
      plan = described_class.new(level: "standard", interests: [], include_phrases: false).call
      expect(plan.phrases_page).to be_nil
    end

    it "still includes the Phrases page for a glp-stage communicator even when opted out" do
      plan = described_class.new(level: "standard", profile: profile(glp_stage: 1),
                                 interests: [], include_phrases: false).call
      expect(plan.phrases_page).to include(include: true, prominence: :strip)
    end
  end
end
