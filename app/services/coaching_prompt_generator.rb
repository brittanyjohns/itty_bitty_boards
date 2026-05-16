require "json"

# Returns a CoachingPromptSet appropriate for a given board, in this priority:
#
#   1. Curated published set whose match_tags intersect the board's tags/name.
#   2. Previously cached AI-generated set, looked up via
#      `board.metadata["coaching_prompt_set_id"]`.
#   3. Bundled fallback set in staging (mirrors the OpenAI image staging stub
#      pattern documented in CLAUDE.md), so we never burn paid AI calls there.
#   4. A fresh AI-generated set from OpenAI, persisted with
#      `source: "ai_generated"` and cached on the board's metadata jsonb.
#
# Free to call — there is no credit gating in v1. Cost is bounded because
# step 4 only runs once per unique board (lifetime).
class CoachingPromptGenerator
  MODEL = ENV.fetch("OPENAI_COACHING_MODEL", "gpt-4o-mini")
  FALLBACK_SLUG = "default_fallback".freeze

  class << self
    def for(board)
      return fallback_set if board.nil?

      curated = CoachingPromptSet.match_for(board)
      return curated if curated

      cached = cached_set_for(board)
      return cached if cached

      return fallback_set if AppEnv.staging?

      generated = generate_from_openai(board)
      return fallback_set unless generated

      persist!(board, generated)
    rescue => e
      Rails.logger.error "[CoachingPromptGenerator] #{e.class}: #{e.message}"
      fallback_set
    end

    private

    def cached_set_for(board)
      id = board.metadata.is_a?(Hash) ? board.metadata["coaching_prompt_set_id"] : nil
      return nil if id.blank?

      CoachingPromptSet.find_by(id: id)
    end

    def persist!(board, attrs)
      set = CoachingPromptSet.create!(
        name: attrs[:name].presence || board.name,
        slug: unique_slug_for(board),
        description: attrs[:description],
        strategies: attrs[:strategies] || [],
        match_tags: Array(board.try(:tags)).map { |t| t.to_s.downcase },
        source: "ai_generated",
        published: true,
        language: board.language.presence || "en",
      )
      board.metadata = (board.metadata || {}).merge("coaching_prompt_set_id" => set.id)
      board.save!(validate: false)
      set
    end

    def unique_slug_for(board)
      base = "ai_board_#{board.id}"
      slug = base
      i = 1
      while CoachingPromptSet.exists?(slug: slug)
        slug = "#{base}_#{i}"
        i += 1
      end
      slug
    end

    def generate_from_openai(board)
      messages = [
        { role: "system", content: system_prompt },
        { role: "user", content: user_prompt_for(board) },
      ]
      response = openai_client.chat(
        parameters: {
          model: MODEL,
          messages: messages,
          response_format: { type: "json_object" },
        },
      )
      content = response.dig("choices", 0, "message", "content")
      return nil if content.blank?

      parsed = JSON.parse(content)
      {
        name: parsed["name"] || board.name,
        description: parsed["description"],
        strategies: Array(parsed["strategies"]).map { |s| normalize_strategy(s) }.compact,
      }
    rescue JSON::ParserError => e
      Rails.logger.warn "[CoachingPromptGenerator] bad JSON: #{e.message}"
      nil
    end

    def normalize_strategy(s)
      return nil unless s.is_a?(Hash)
      label = s["label"].to_s.strip
      return nil if label.blank?
      {
        "label" => label,
        "hint" => s["hint"].to_s.strip,
        "example_phrases" => Array(s["example_phrases"]).map(&:to_s).reject(&:blank?),
      }
    end

    def system_prompt
      <<~PROMPT
        You are coaching a caregiver — a grandparent, sibling, babysitter, or
        teacher — to be a better communication partner for an AAC user during
        a real-life activity. The user is opening an AAC board in their app and
        wants gentle, non-clinical, warm coaching prompts.

        Respond with a single JSON object with this shape:

        {
          "name": "short context name",
          "description": "one sentence of caregiver-facing context",
          "strategies": [
            {
              "label": "Short strategy name (e.g. Offer a choice)",
              "hint": "One short sentence telling the caregiver what to try.",
              "example_phrases": ["A sample phrase a caregiver can say.", "Another."]
            }
          ]
        }

        Rules:
        - 4 to 6 strategies.
        - 2 to 4 example_phrases per strategy.
        - Tone: warm, plain English, no jargon, no clinical language, no acronyms.
        - Phrases should sound like something a loving grown-up would naturally say.
        - Avoid yes/no test questions. Favor open-ended invitations and modeled language.
      PROMPT
    end

    def user_prompt_for(board)
      tag_str = Array(board.try(:tags)).join(", ").presence || "(none)"
      <<~USER
        Board name: #{board.name}
        Board description: #{board.description.presence || "(none)"}
        Board tags: #{tag_str}

        Generate the caregiver coaching prompt set for this board.
      USER
    end

    def openai_client
      OpenAI::Client.new(access_token: ENV["OPENAI_ACCESS_TOKEN"], log_errors: true)
    end

    # The fallback row is upserted by db/seeds.rb and is therefore expected to
    # exist in every environment. If it has been deleted, fall back to a
    # transient in-memory record so the API never 500s.
    def fallback_set
      CoachingPromptSet.find_by(slug: FALLBACK_SLUG) || build_transient_fallback
    end

    def build_transient_fallback
      CoachingPromptSet.new(
        name: "Connecting through play",
        slug: FALLBACK_SLUG,
        description: "Gentle ways to keep the conversation going.",
        strategies: CoachingPromptSeedData::DEFAULT_FALLBACK_STRATEGIES,
        match_tags: [],
        source: "curated",
        published: true,
        language: "en",
      )
    end
  end
end
