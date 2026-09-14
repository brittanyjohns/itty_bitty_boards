# app/services/communicator_likeness.rb
# Purpose: how the people in a communicator's AI tile art should look — skin
# tone, hair, gender presentation, and things like glasses or a wheelchair — so
# a board can look like the person using it.
#
# Stored as allowlisted TOKENS (child_accounts.settings["likeness"], and a
# per-board override in boards.settings["likeness"]). The client never sends
# prompt text: every sentence that reaches the image model is composed here from
# phrases this class owns, the same trust boundary Images::TextTile::Options
# draws for CSS. Unknown tokens are DROPPED rather than rejected, like
# Images::PromptBuilder.resolve_style, so a stale client can't break a save.
#
# A likeness with no usable fields is `blank?`, and callers treat it as "no
# likeness" — generation behaves exactly as before.
class CommunicatorLikeness
  FIELDS = {
    "skin_tone" => %w[light light_medium medium medium_brown brown dark_brown],
    "hair_color" => %w[black dark_brown brown auburn red blond gray],
    "hair_style" => %w[short long curly coily braids locs ponytail buzzed bald],
    "gender_presentation" => %w[boy_man girl_woman neutral],
  }.freeze

  EXTRAS = %w[glasses hearing_aids wheelchair walker hijab turban kippah braces aac_device].freeze

  # A board override that turns likeness OFF for that board, as distinct from a
  # board with no override (which inherits from its communicator).
  NONE_MODE = "none".freeze

  # Rough swatches so a picker can show the tone rather than only name it.
  SKIN_TONE_SWATCHES = {
    "light" => "#F6D5C1",
    "light_medium" => "#E7B98F",
    "medium" => "#CF9C74",
    "medium_brown" => "#A6724B",
    "brown" => "#7C5033",
    "dark_brown" => "#4A2C1D",
  }.freeze

  SKIN_PHRASES = {
    "light" => "light skin",
    "light_medium" => "light-medium skin",
    "medium" => "medium skin",
    "medium_brown" => "medium-brown skin",
    "brown" => "brown skin",
    "dark_brown" => "dark brown skin",
  }.freeze

  HAIR_COLOR_PHRASES = {
    "black" => "black",
    "dark_brown" => "dark brown",
    "brown" => "brown",
    "auburn" => "auburn",
    "red" => "red",
    "blond" => "blond",
    "gray" => "gray",
  }.freeze

  EXTRA_PHRASES = {
    "glasses" => "wearing glasses",
    "hearing_aids" => "wearing hearing aids",
    "wheelchair" => "using a wheelchair",
    "walker" => "using a walker",
    "hijab" => "wearing a hijab",
    "turban" => "wearing a turban",
    "kippah" => "wearing a kippah",
    "braces" => "with braces on their teeth",
    "aac_device" => "holding a tablet communication device",
  }.freeze

  # Who the person is, by the communicator's age band (CommunicatorProfile) and
  # gender presentation. With no band the noun stays age-neutral: communicators
  # are not all children.
  AGE_NOUNS = {
    "under-4" => { "boy_man" => "toddler boy", "girl_woman" => "toddler girl", "neutral" => "toddler" },
    "4-6" => { "boy_man" => "young boy", "girl_woman" => "young girl", "neutral" => "young child" },
    "7-10" => { "boy_man" => "boy", "girl_woman" => "girl", "neutral" => "child" },
    "11-14" => { "boy_man" => "preteen boy", "girl_woman" => "preteen girl", "neutral" => "preteen" },
    "15-18" => { "boy_man" => "teenage boy", "girl_woman" => "teenage girl", "neutral" => "teenager" },
    "adult" => { "boy_man" => "man", "girl_woman" => "woman", "neutral" => "adult" },
  }.freeze
  UNAGED_NOUNS = {
    "boy_man" => "masculine-presenting person",
    "girl_woman" => "feminine-presenting person",
    "neutral" => "person",
  }.freeze

  PROMPT_GUARD = "Do not add any other people the subject does not need.".freeze

  attr_reader :skin_tone, :hair_color, :hair_style, :gender_presentation, :extras

  # Accepts a Hash, ActionController::Parameters, or anything else (which is
  # treated as empty). Always returns an instance; check `blank?`.
  def self.from_hash(value)
    value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
    value = {} unless value.is_a?(Hash)
    value = value.stringify_keys

    new(
      **FIELDS.keys.to_h { |field| [field.to_sym, token(value[field], FIELDS[field])] },
      extras: Array(value["extras"]).filter_map { |extra| token(extra, EXTRAS) }.uniq.sort,
    )
  end

  # What a board's settings["likeness"] may hold: the NONE_MODE marker, a
  # likeness hash, or nothing at all (nil — the caller removes the key, and the
  # board inherits).
  def self.normalize_board_setting(value)
    value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
    return { "mode" => NONE_MODE } if value.is_a?(Hash) && value.stringify_keys["mode"].to_s == NONE_MODE

    likeness = from_hash(value)
    likeness.blank? ? nil : likeness.to_h
  end

  def self.token(raw, allowed)
    normalized = raw.to_s.strip.downcase
    allowed.include?(normalized) ? normalized : nil
  end
  private_class_method :token

  # The picker's option lists, labelled for `locale`.
  def self.options(locale: I18n.default_locale)
    fields = FIELDS.to_h do |field, values|
      options = values.map do |value|
        option = { value: value, label: I18n.t("likeness.#{field}.#{value}", locale: locale) }
        option[:swatch] = SKIN_TONE_SWATCHES[value] if field == "skin_tone"
        option
      end
      [field, { label: I18n.t("likeness.fields.#{field}", locale: locale), options: options }]
    end
    extras = {
      label: I18n.t("likeness.fields.extras", locale: locale),
      options: EXTRAS.map { |value| { value: value, label: I18n.t("likeness.extras.#{value}", locale: locale) } },
    }

    { fields: fields, extras: extras }
  end

  def initialize(skin_tone: nil, hair_color: nil, hair_style: nil, gender_presentation: nil, extras: [])
    @skin_tone = skin_tone
    @hair_color = hair_color
    @hair_style = hair_style
    @gender_presentation = gender_presentation
    @extras = extras
  end

  def blank?
    to_h.empty?
  end

  def present?
    !blank?
  end

  def to_h
    {
      "skin_tone" => skin_tone,
      "hair_color" => hair_color,
      "hair_style" => hair_style,
      "gender_presentation" => gender_presentation,
      "extras" => extras.presence,
    }.compact
  end

  # Stable across key and extras order, so two communicators who look the same
  # produce the same value — what lets generated art be reused between them.
  def fingerprint
    return nil if blank?

    Digest::SHA256.hexdigest(to_h.sort.to_h.to_json)[0, 16]
  end

  # One sentence for Images::PromptBuilder, or nil when there is nothing to say.
  # Only ever sent for a word whose picture IS the communicator — that decision
  # is Images::LikenessApplicability's, never this sentence's. Worded as a
  # conditional ("if the picture shows a person…") it rode every prompt, and the
  # model drew the person it described into "dog" and "she" alike.
  def prompt_clause(age_band: nil)
    return nil if blank?

    descriptors = [SKIN_PHRASES[skin_tone], hair_phrase].compact
    noun = person_noun(age_band)
    description = "#{noun.match?(/\A[aeiou]/i) ? "an" : "a"} #{noun}"
    description += " with #{descriptors.join(" and ")}" if descriptors.any?
    extra_phrases = extras.filter_map { |extra| EXTRA_PHRASES[extra] }
    description += ", #{extra_phrases.to_sentence}" if extra_phrases.any?

    "Draw the person in this picture as #{description}. #{PROMPT_GUARD}"
  end

  # A readable tag for a picture drawn with this look, e.g.
  # "Skin tone: Brown · Hair style: Curly · Also include: Glasses · 4–6 years".
  # Built from the picker's own locale labels, never from the prompt phrases, so
  # it names the look in the words it was chosen in. nil when blank.
  def label(locale: I18n.default_locale, age_band: nil)
    return nil if blank?

    parts = FIELDS.keys.filter_map do |field|
      value = public_send(field)
      next if value.nil?

      "#{I18n.t("likeness.fields.#{field}", locale: locale)}: #{I18n.t("likeness.#{field}.#{value}", locale: locale)}"
    end
    if extras.any?
      names = extras.map { |extra| I18n.t("likeness.extras.#{extra}", locale: locale) }
      parts << "#{I18n.t("likeness.fields.extras", locale: locale)}: #{names.join(", ")}"
    end
    band = CommunicatorProfile.age_band_label(age_band, locale: locale) if age_band.present?
    parts << band if band

    parts.join(" · ")
  end

  private

  def person_noun(age_band)
    presentation = gender_presentation || "neutral"
    AGE_NOUNS.dig(age_band.to_s, presentation) || UNAGED_NOUNS.fetch(presentation)
  end

  def hair_phrase
    return "a bald head" if hair_style == "bald"

    color = HAIR_COLOR_PHRASES[hair_color]
    return nil if color.nil? && hair_style.nil?

    case hair_style
    when "braids" then [color, "braided hair"].compact.join(" ")
    when "locs" then [color, "locs"].compact.join(" ")
    when "ponytail" then "#{[color, "hair"].compact.join(" ")} in a ponytail"
    else [hair_style, color, "hair"].compact.join(" ")
    end
  end
end
