module Boards
  class StructurePlanner
    LEVELS = {
      "starter"  => { core_template: "core-60", min_pages: 4, max_pages: 6 },
      "standard" => { core_template: "core-60", min_pages: 8, max_pages: 10 },
      "extended" => { core_template: "core-84", min_pages: 10, max_pages: 15 },
    }.freeze

    LEVEL_KEYS = LEVELS.keys.freeze

    STARTER_DEFAULTS  = %w[Food Feelings].freeze
    STANDARD_DEFAULTS = %w[Food Feelings Play People].freeze
    EXTENDED_DEFAULTS = %w[Food Feelings Play People Places Body Social].freeze

    # Fringe pages that ship with each seed set (authored content, stable).
    SEED_SET_PAGES = {
      "core-60" => %w[People Feelings Food Drinks Play Places Body More],
      "core-84" => %w[People Feelings Food Drinks Play Places Body More School Time Describe],
    }.freeze

    # InterestCategories names that map to a differently-named seed set page.
    CATEGORY_SEED_ALIASES = {
      "Family & People" => "People",
      "Health & Body" => "Body",
    }.freeze

    AI_CREDITS_PER_PAGE = CreditService.cost_for("ai_board_page")

    Result = Struct.new(
      :level, :core_template, :fringe_pages, :excluded_fringe_pages,
      :catch_all_interests, :ai_credits_needed,
      keyword_init: true,
    )

    def initialize(level:, profile: nil, interests: [], explicit_categories: {}, user: nil)
      @level = normalize_level(level)
      @profile = profile
      @interests = interests
      @explicit_categories = explicit_categories || {}
      @user = user
      @config = LEVELS.fetch(@level)
    end

    def call
      categorized = categorize_interests
      needed_categories = collect_needed_categories(categorized)
      fringe_pages = plan_fringe_pages(needed_categories, categorized)
      fringe_pages = cap_pages(fringe_pages)

      excluded = compute_excluded(fringe_pages)
      catch_all = collect_catch_all(categorized, fringe_pages)
      ai_credits = fringe_pages.count { |p| p[:source] == :ai_generated } * AI_CREDITS_PER_PAGE

      if @user && ai_credits > 0
        fringe_pages, catch_all, ai_credits = downgrade_ai_pages_if_needed(
          fringe_pages, catch_all, ai_credits,
        )
      end

      Result.new(
        level: @level,
        core_template: @config[:core_template],
        fringe_pages: fringe_pages,
        excluded_fringe_pages: excluded,
        catch_all_interests: catch_all,
        ai_credits_needed: ai_credits,
      )
    end

    private

    def normalize_level(level)
      key = level.to_s.downcase
      return key if LEVELS.key?(key)

      case key
      when "core-60" then "standard"
      when "core-84" then "extended"
      else "standard"
      end
    end

    def categorize_interests
      @interests.each_with_object({}) do |word, map|
        category = @explicit_categories[word] ||
                   Boards::InterestCategories.category_for(word)
        bucket = category || :uncategorized
        (map[bucket] ||= []) << word
      end
    end

    def collect_needed_categories(categorized)
      from_interests = categorized.keys.reject { |k| k == :uncategorized }
      defaults = default_categories_for_level
      (from_interests + defaults).uniq
    end

    def default_categories_for_level
      case @level
      when "starter"  then STARTER_DEFAULTS
      when "extended" then EXTENDED_DEFAULTS
      else STANDARD_DEFAULTS
      end
    end

    def plan_fringe_pages(needed_categories, categorized)
      needed_categories.map do |category|
        interests_for = categorized[category] || []
        source = source_for_category(category)
        { name: category, source: source, interests: interests_for }
      end
    end

    def source_for_category(category)
      return :seed_set if in_seed_set?(category)
      return :prebuilt if Boards::FringeTemplates.find(category).present?

      :ai_generated
    end

    def in_seed_set?(category)
      pages = SEED_SET_PAGES[@config[:core_template]] || []
      seed_name = CATEGORY_SEED_ALIASES[category] || category
      pages.any? { |p| p.downcase == seed_name.downcase }
    end

    def cap_pages(fringe_pages)
      max = @config[:max_pages]
      return fringe_pages if fringe_pages.size <= max

      with_interests, without = fringe_pages.partition { |p| p[:interests].any? }
      kept = with_interests.first(max)
      remaining_slots = max - kept.size
      kept += without.first(remaining_slots) if remaining_slots > 0
      kept
    end

    def compute_excluded(planned_fringe)
      pages = SEED_SET_PAGES[@config[:core_template]] || []
      planned_seed_names = planned_fringe
        .select { |p| p[:source] == :seed_set }
        .map { |p| CATEGORY_SEED_ALIASES[p[:name]] || p[:name] }
        .map(&:downcase)

      pages.reject { |name| planned_seed_names.include?(name.downcase) }
    end

    def collect_catch_all(categorized, fringe_pages)
      result = categorized[:uncategorized]&.dup || []

      planned_categories = fringe_pages.map { |p| p[:name] }
      categorized.each do |category, words|
        next if category == :uncategorized
        next if planned_categories.include?(category)

        result += words
      end

      result
    end

    def downgrade_ai_pages_if_needed(fringe_pages, catch_all, ai_credits)
      available = CreditService.balance(@user)[:total]
      return [fringe_pages, catch_all, ai_credits] if available >= ai_credits

      kept = []
      remaining_credits = available
      overflow_interests = catch_all.dup

      fringe_pages.each do |page|
        if page[:source] == :ai_generated
          if remaining_credits >= AI_CREDITS_PER_PAGE
            kept << page
            remaining_credits -= AI_CREDITS_PER_PAGE
          else
            overflow_interests += (page[:interests] || [])
          end
        else
          kept << page
        end
      end

      final_ai_credits = kept.count { |p| p[:source] == :ai_generated } * AI_CREDITS_PER_PAGE
      [kept, overflow_interests, final_ai_credits]
    end
  end
end
