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
  def clean(value, limit)
    text = value.to_s
    2.times { text = CGI.unescapeHTML(strip_tags(text)) }
    text = text.squish
    return nil if text.blank?

    text[0, limit]
  end

  def strip_tags(value)
    ActionController::Base.helpers.strip_tags(value)
  end
end
