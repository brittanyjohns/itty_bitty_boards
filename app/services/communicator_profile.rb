# app/services/communicator_profile.rb
# Purpose: Normalize an optional communicator profile (age, AAC level, vocabulary
# type) passed from the frontend's "Who is this board for?" picker, and turn it
# into a single guidance string that gets appended to AI word-suggestion prompts.
#
# Every field is optional. A profile with no usable fields is `blank?` and
# callers treat it as "no profile" — generation behaves exactly as before.

class CommunicatorProfile
  AAC_LEVELS = %w[emerging developing proficient].freeze
  VOCAB_TYPES = %w[core fringe balanced].freeze
  AGE_BANDS = %w[4-6 7-10 11-14 15-18 adult].freeze
  # Natural Language Acquisition (NLA) stages for gestalt language processors,
  # 1–6. Optional metadata stored as an INTEGER (unlike the string enums above)
  # — see ChildAccount#normalize_aac_profile_fields for the int handling.
  GLP_STAGES = (1..6).to_a.freeze

  attr_reader :age, :age_band, :aac_level, :vocab_type, :glp_stage

  # Build from a params-like hash (string or symbol keys). Returns nil when no
  # usable profile data is present, so callers can do `CommunicatorProfile.from_params(...)`
  # and treat nil as "no profile".
  def self.from_params(params)
    return nil if params.blank?

    fetch = ->(key) { params[key] || params[key.to_s] }
    profile = new(
      age: fetch.call(:age),
      age_band: fetch.call(:age_band),
      aac_level: fetch.call(:aac_level),
      vocab_type: fetch.call(:vocab_type),
      glp_stage: fetch.call(:glp_stage),
      age_range: fetch.call(:age_range)
    )
    profile.present? ? profile : nil
  end

  # Merge constructor: request params override the communicator's stored
  # profile (child_accounts.details), field by field — an explicit picker value
  # wins, anything the picker left blank falls back to what's stored on the
  # communicator. Returns nil when neither source has usable data, preserving
  # the "no profile = unchanged behavior" contract of from_params.
  def self.for(params: nil, communicator: nil)
    fetch = ->(key) { params && (params[key] || params[key.to_s]).presence }
    stored = communicator&.details || {}
    profile = new(
      age: fetch.call(:age) || stored["age"],
      age_band: fetch.call(:age_band) || stored["age_band"],
      aac_level: fetch.call(:aac_level) || stored["aac_level"],
      vocab_type: fetch.call(:vocab_type) || stored["vocab_type"],
      glp_stage: fetch.call(:glp_stage) || stored["glp_stage"],
      age_range: fetch.call(:age_range)
    )
    profile.present? ? profile : nil
  end

  # `age_range` is the legacy free-text param already used by the scenario flow;
  # it's accepted as a fallback when no structured age/age_band is given.
  def initialize(age: nil, age_band: nil, aac_level: nil, vocab_type: nil, glp_stage: nil, age_range: nil)
    @age = normalize_age(age)
    @age_band = normalize_age_band(age_band) || band_for_age(@age) || normalize_age_band(age_range)
    @aac_level = normalize_enum(aac_level, AAC_LEVELS)
    @vocab_type = normalize_enum(vocab_type, VOCAB_TYPES)
    @glp_stage = normalize_glp_stage(glp_stage)
  end

  def present?
    age.present? || age_band.present? || aac_level.present? ||
      vocab_type.present? || glp_stage.present?
  end

  def blank?
    !present?
  end

  # Young / emerging communicators get core-word-heavy guidance.
  def young?
    return age <= 10 if age.present?

    %w[4-6 7-10].include?(age_band)
  end

  def emerging?
    aac_level == "emerging" || (aac_level.nil? && young?)
  end

  def developing?
    aac_level == "developing"
  end

  def young_teen?
    return age.between?(11, 14) if age.present?

    age_band == "11-14"
  end

  # Gestalt language processing (NLA) stage predicates. All false when no
  # glp_stage is set, so non-GLP communicators behave exactly as before.
  def gestalt_early?
    glp_stage.present? && glp_stage <= 2
  end

  def gestalt_emerging?
    glp_stage.present? && glp_stage.between?(3, 4)
  end

  def gestalt_advanced?
    glp_stage.present? && glp_stage >= 5
  end

  # Single string appended to AI prompts. Empty when the profile is blank.
  def prompt_guidance
    return "" if blank?

    [descriptor_sentence, level_guidance, vocab_guidance, gestalt_guidance].compact.join(" ")
  end

  private

  def normalize_age(value)
    return nil if value.blank?

    age = value.to_i
    age.between?(0, 120) ? age : nil
  end

  def normalize_age_band(value)
    return nil if value.blank?

    band = value.to_s.strip.downcase
    AGE_BANDS.include?(band) ? band : nil
  end

  def normalize_enum(value, allowed)
    return nil if value.blank?

    normalized = value.to_s.strip.downcase
    allowed.include?(normalized) ? normalized : nil
  end

  def normalize_glp_stage(value)
    return nil if value.blank?

    stage = value.to_i
    GLP_STAGES.include?(stage) ? stage : nil
  end

  def band_for_age(age)
    return nil if age.blank?

    case age
    when 0..6   then "4-6"
    when 7..10  then "7-10"
    when 11..14 then "11-14"
    when 15..18 then "15-18"
    else "adult"
    end
  end

  def descriptor_sentence
    bits = []
    bits << "age band #{age_band}" if age_band.present?
    bits << "AAC level #{aac_level}" if aac_level.present?
    context = bits.any? ? " (#{bits.join(', ')})" : ""
    "This communication board is for a specific communicator#{context}."
  end

  def level_guidance
    if emerging?
      "Prioritize core vocabulary — roughly 80% of typical AAC use — favoring " \
        "high-frequency verbs, pronouns, simple describing words, emotions, and " \
        "social/interaction words (for example: more, help, all done, stop, want, " \
        "go, like, my). Avoid clinically literate, topic-specific, or multi-syllable " \
        "adult nouns. Keep words short, concrete, and developmentally appropriate."
    elsif aac_level == "developing"
      "Balance core vocabulary with the most relevant topic words, and keep the " \
        "language developmentally appropriate for the communicator's age."
    elsif aac_level == "proficient"
      "A richer mix of topic-specific and fringe vocabulary is appropriate — " \
        "include precise nouns and varied phrasing suitable for the communicator's age."
    end
  end

  def vocab_guidance
    case vocab_type
    when "core"
      "Strongly favor core vocabulary over topic-specific fringe words."
    when "fringe"
      "Favor topic-specific fringe vocabulary relevant to the board's theme."
    when "balanced"
      "Aim for a balanced mix of core and fringe vocabulary."
    end
  end

  # Gestalt-language-processor guidance, keyed to the NLA stage. Nil (and so
  # dropped from prompt_guidance) when no glp_stage is set — keeps prompts for
  # non-GLP communicators unchanged.
  def gestalt_guidance
    return nil if glp_stage.blank?

    intro = "This communicator is a gestalt language processor at NLA Stage #{glp_stage}."
    if gestalt_early?
      "#{intro} Use whole familiar phrases and scripts, not single words. " \
        "Prioritize phrases from their daily routines, favorite shows, and songs. " \
        "Avoid isolated vocabulary."
    elsif gestalt_emerging?
      "#{intro} Mix single words with short phrases. Support novel 2-3 word " \
        "combinations. Include both whole phrases and individual high-frequency words."
    else
      "#{intro} Use full sentences with varied grammar. Support complex sentence " \
        "construction with verb tenses and modifiers."
    end
  end
end
