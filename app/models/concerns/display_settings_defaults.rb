# The boolean display/behaviour flags stored in the `settings` jsonb, and the
# default each one takes when nothing has written it yet.
#
# A communicator's board renders from the SAME keys its owner's board does, so
# the two models cannot be allowed to disagree about what an absent key means.
# They did: `User` seeded these on save while `ChildAccount` seeded nothing, and
# the frontend papered over the gap with per-form fallbacks that contradicted
# each other (`?? true` on one communicator form, `|| false` on another). The
# effective default for a communicator therefore depended on which screen had
# created it. Extracting the lists is what stops that drifting again — a key
# added here is defaulted identically on both models.
#
# An ABSENT key is what gets a default; a stored `false` is a choice and is
# left alone. Note `settings` has no DB default on either table, so it can be
# nil on any row — every method here treats nil as "nothing stored yet".
module DisplaySettingsDefaults
  extend ActiveSupport::Concern

  REQUIRED_SETTINGS = %w[
    wait_to_speak disable_audit_logging enable_image_display enable_text_display
    show_labels show_tutorial
  ].freeze

  DEFAULT_FALSE_SETTINGS = %w[wait_to_speak disable_audit_logging enable_text_display].freeze
  DEFAULT_TRUE_SETTINGS = %w[enable_image_display show_labels show_tutorial].freeze

  def all_required_settings
    REQUIRED_SETTINGS
  end

  def false_settings
    DEFAULT_FALSE_SETTINGS
  end

  def true_settings
    DEFAULT_TRUE_SETTINGS
  end

  # Keyed on "is a value stored", never on truthiness — a legitimately stored
  # `false` is a complete setting, not a missing one.
  def has_all_settings?
    stored = settings
    return false unless stored.is_a?(Hash)

    all_required_settings.all? { |setting| !stored[setting].nil? }
  end

  def ensure_settings
    self.settings = {} unless settings
    all_required_settings.each do |setting|
      next unless settings[setting].nil?

      settings[setting] = false if false_settings.include?(setting)
      settings[setting] = true if true_settings.include?(setting)
    end
    settings
  end
end
