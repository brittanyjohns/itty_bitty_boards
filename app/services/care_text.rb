# frozen_string_literal: true

# The single cleaning rule for every free-text care value.
#
# Lives here rather than inline on Profile because the repair task
# (CareTextRepair) has to apply the IDENTICAL rule to already-stored rows — two
# copies of it would drift, and the two halves disagreeing is exactly what
# leaves a profile half-fixed.
module CareText
  module_function

  # Strips markup and returns the text UNESCAPED, capped at `limit`.
  #
  # The subtlety is that strip_tags escapes entities on OUTPUT, so a single
  # pass turns "hugs & quiet" into "hugs &amp; quiet" — and because the cleaner
  # runs in a before_save, that escaped form is what lands in the database and
  # shows up verbatim on the public page and in the printed care plan.
  #
  # So: strip, then unescape — twice. The second pass matters because the first
  # unescape can REVEAL markup that arrived escaped ("&lt;script&gt;"), and that
  # has to be stripped rather than stored. The second unescape then undoes the
  # second strip's own re-escaping. Unescaping only once at the end would leave
  # the ampersand escaped, which is the bug this exists to fix.
  #
  # Idempotent: cleaning an already-clean value is a no-op, so re-saving a
  # profile can't compound the escaping and the repair task is safe to re-run.
  #
  # `multiline:` is the one thing that varies, and it is a fact about the FIELD,
  # never about the value: a section's `short_text` field is a textarea a parent
  # types a list into ("he bolts when scared / rides Bus 14 / front-right seat"),
  # and squishing that into one paragraph is the shape a substitute teacher or a
  # paramedic has to read in a hurry. Everything else here — a section title, a
  # detail row's label and value, a custom chip — is a one-line control, so a
  # pasted newline there is noise and still collapses to a space. Which fields
  # are which is answered by .multiline? so the sanitizer and the repair task
  # cannot disagree about it.
  #
  # Horizontal whitespace is still collapsed, whitespace around a break is still
  # dropped, and a run of blank lines is still capped at one — only the single
  # line break survives.
  def clean(value, limit, multiline: false)
    text = value.to_s
    2.times { text = CGI.unescapeHTML(strip_tags(text)) }
    text = multiline ? squish_preserving_breaks(text) : text.squish
    return nil if text.blank?

    text = text[0, limit].rstrip
    text.presence
  end

  # A field type whose control is multi-line. `short_text` is the per-section
  # free-text field — the only multi-line surface in the care registry.
  MULTILINE_FIELD_TYPES = %i[short_text].freeze

  def multiline?(field_type)
    MULTILINE_FIELD_TYPES.include?(field_type.to_s.to_sym)
  end

  def squish_preserving_breaks(text)
    text
      .gsub(/\r\n?/, "\n")
      .gsub(/[^\S\n]+/, " ")
      .gsub(/ *\n */, "\n")
      .gsub(/\n{3,}/, "\n\n")
      .strip
  end

  def strip_tags(value)
    ActionController::Base.helpers.strip_tags(value)
  end
end
