# app/services/images/prompt_builder.rb
# Purpose: the single source of truth for every text-to-image prompt we send to
# OpenAI. Before this existed, six different methods each defined their own
# (mutually contradictory) house style — "no stylization" vs "clipart-style" vs
# "simple cartoon illustration" vs "avoid cartoonish styles" — so tiles on one
# board could not look like a set.
#
# The builder ALWAYS wraps: a user's typed prompt becomes the subject line
# inside the house envelope rather than replacing it. The only way to send a raw
# prompt is `raw: true`, which is admin-only at the controller layer.
#
# Prompt layers, in order:
#   1. subject          — the user's input, else the label
#   2. disambiguation   — from part_of_speech, only when it adds information
#   3. appearance mods  — the bulk "apply to every selected tile" field
#   4. style spec       — STYLES[:symbol] or STYLES[:illustrated]
#   5. hard constraints — always; no text, single subject, background rule
module Images
  class PromptBuilder
    SYMBOL = "symbol".freeze
    ILLUSTRATED = "illustrated".freeze
    STYLE_NAMES = [SYMBOL, ILLUSTRATED].freeze

    # The style used when neither the request, the board, nor the user has
    # picked one. `symbol` is the AAC-correct look and the most legible at the
    # 288px tile variant size. Changing this constant changes the default for
    # every future generation; it never touches already-generated images.
    DEFAULT_STYLE = SYMBOL

    STYLES = {
      SYMBOL => "Draw it as a flat vector AAC communication symbol: bold, clean, " \
                "uniform dark outlines, flat solid fills, and a small high-contrast " \
                "color palette. No shading, no gradients, no texture, no perspective, " \
                "no drop shadows, and no background scenery.",
      ILLUSTRATED => "Draw it as a simple, friendly illustration: soft flat colors with " \
                     "light shading, clean readable shapes, and no background scenery.",
    }.freeze

    # Applied to every prompt regardless of style. "No text" is repeated in
    # concrete terms because image models routinely add captions to icon-like
    # requests when told only "no text".
    BASE_CONSTRAINTS = "Show a single subject, centered, filling most of the frame. " \
                       "Do not include any text, letters, numbers, labels, captions, " \
                       "or watermarks in the image.".freeze

    TRANSPARENT_CONSTRAINT = "The background must be fully transparent.".freeze
    OPAQUE_CONSTRAINT = "Use a plain, solid, uncluttered background.".freeze

    # The bulk editor's "apply to every selected tile" field — skin tone,
    # contrast, line weight. Unlike `user_input` it describes how the picture
    # LOOKS, never what it is of, so it is a separate layer rather than a second
    # way to write the subject. The guard sentence is not decoration: without it
    # a modifier phrased as a noun ("a brown-skinned child") is read as the
    # subject by the model and every selected tile comes back as the same
    # picture, which is the exact failure this layer exists to avoid.
    MAX_MODIFIERS_LENGTH = 240
    MODIFIERS_LEAD_IN = "Apply these appearance instructions to the whole picture:".freeze
    MODIFIERS_GUARD = "Keep the subject exactly as described above; these instructions " \
                      "change only how it looks.".freeze

    # Part-of-speech clauses exist to disambiguate AAC homographs — "can",
    # "orange", "watch", "left", "back", "second", "fly", "ring" all render as
    # the wrong concept without them. We already compute and store
    # part_of_speech (AacWordCategorizer) to color the tile; this puts that
    # signal to work a second time.
    #
    # Categories that carry no useful visual instruction (conjunction,
    # determiner, default) are intentionally absent — a nil clause is dropped.
    POS_CLAUSES = {
      "verb" => "Depict the action itself: a single person performing it, " \
                "caught mid-action so the movement is obvious.",
      "adjective" => "Depict the quality or property itself, shown clearly on one " \
                     "simple everyday object or person.",
      "noun" => "Depict the physical object or thing itself.",
      "pronoun" => "Depict the person or people it refers to, using a clear pointing " \
                   "or self-referential gesture.",
      "preposition" => "Depict the spatial relationship between two simple objects, " \
                       "so the position is the point of the picture.",
      "social" => "Depict a person making the everyday gesture or facial expression " \
                  "used for this greeting or social phrase.",
      "question" => "Depict a person with a clearly questioning expression and gesture.",
      "adverb" => "Depict the manner or degree it describes, shown through one " \
                  "person's action.",
      "important_function" => "Depict the meaning with a clear, universally understood " \
                              "gesture or hand sign.",
    }.freeze

    attr_reader :label, :user_input, :part_of_speech, :style, :transparent, :modifiers

    # Free text from a user, made safe to drop into a composed prompt.
    #
    # The `[[...]]` strip is load-bearing: `[[REPLACE_LABEL]]` is the ADMIN-only
    # raw-prompt escape hatch that API::ImagesController#generate honours, and
    # the bulk fields this sanitizes are the first place a NON-admin's free text
    # reaches the composer. Control characters go too — a newline lets a user
    # visually "end" our prompt and start their own.
    #
    # Returns nil for anything that reduces to blank, so a caller can treat
    # "typed nothing" and "typed only whitespace" identically.
    def self.sanitize_user_text(value, max_length:)
      text = value.to_s
        .gsub(/\[\[.*?\]\]/, " ")
        .gsub(/[[:cntrl:]]/, " ")
        .squish
        .slice(0, max_length).to_s
        .strip
      return nil if text.blank?
      return text if text.end_with?(".", "!", "?")
      # max_length is a ceiling on what we EMIT, so text already at the cap
      # keeps its (lossy) truncation rather than growing a 241st character. The
      # terminator only matters for text we didn't cut — it stops the next
      # clause running into the user's last word.
      return text if text.length >= max_length

      "#{text}."
    end

    def self.sanitize_modifiers(value)
      sanitize_user_text(value, max_length: MAX_MODIFIERS_LENGTH)
    end

    # Resolves the style for a generation: an explicit request param wins, then
    # the board's setting, then the user's, then the default. Unknown values
    # fall through rather than raising, so a stale client can't break generation.
    def self.resolve_style(requested: nil, board: nil, user: nil)
      candidates = [
        requested,
        board.is_a?(Board) && board.settings.is_a?(Hash) ? board.settings["image_style"] : nil,
        user.is_a?(User) && user.settings.is_a?(Hash) ? user.settings["image_style"] : nil,
      ]

      candidates.each do |candidate|
        normalized = candidate.to_s.strip.downcase
        return normalized if STYLE_NAMES.include?(normalized)
      end

      DEFAULT_STYLE
    end

    # Convenience wrapper for the common "generate art for this Image record"
    # case, so callers don't have to remember to pass part_of_speech.
    def self.for_image(image, user_input: nil, style: nil, transparent: true, board: nil, user: nil, modifiers: nil)
      new(
        label: image.label,
        user_input: user_input,
        part_of_speech: image.part_of_speech,
        style: style || resolve_style(board: board, user: user || image.user),
        transparent: transparent,
        modifiers: modifiers,
      ).call
    end

    def initialize(label:, user_input: nil, part_of_speech: nil, style: nil, transparent: true, modifiers: nil)
      @label = label.to_s.strip
      @user_input = user_input.to_s.strip
      @part_of_speech = part_of_speech.to_s.strip.downcase
      @style = STYLE_NAMES.include?(style.to_s) ? style.to_s : DEFAULT_STYLE
      @transparent = transparent
      @modifiers = self.class.sanitize_modifiers(modifiers)
    end

    def call
      [subject_clause, pos_clause, modifiers_clause, style_clause, BASE_CONSTRAINTS, background_clause]
        .compact_blank
        .join(" ")
    end

    # The style spec on its own — used by the "suggest a prompt" helper so the
    # suggestion agrees with what we actually generate.
    def style_clause
      STYLES[style]
    end

    private

    def subject_clause
      "Create an image representing '#{subject}'."
    end

    # A user's typed prompt describes the subject; it never replaces the
    # envelope. Falls back to the label when the user typed nothing, or typed
    # only the label back at us (the frontend prefills the field with it).
    def subject
      return label if user_input.blank?
      return label if user_input.casecmp?(label)

      user_input
    end

    # Skipped when the user wrote their own description — their words are more
    # specific than a generic part-of-speech hint, and stacking both produces
    # contradictory instructions.
    def pos_clause
      return nil if user_input.present? && !user_input.casecmp?(label)

      POS_CLAUSES[part_of_speech]
    end

    # Sits AFTER the subject and part-of-speech clauses — each tile keeps its own
    # word — and BEFORE the style spec, so the house style stays the last and
    # therefore most authoritative instruction. A modifier that contradicts it
    # ("watercolor", "photorealistic") loses to it, which is the trade we want:
    # a board full of tiles that no longer match each other is worse than an
    # instruction the model only partly honours.
    def modifiers_clause
      return nil if modifiers.blank?

      "#{MODIFIERS_LEAD_IN} #{modifiers} #{MODIFIERS_GUARD}"
    end

    def background_clause
      transparent ? TRANSPARENT_CONSTRAINT : OPAQUE_CONSTRAINT
    end
  end
end
