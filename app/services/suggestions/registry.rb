module Suggestions
  # Declarative allow-list for every field that can ask for writing suggestions.
  #
  # The client sends a `field_key` and nothing else that reaches OpenAI — the
  # SERVER decides which attributes become prompt context. Adding a new surface
  # is one entry here, not a new subsystem.
  #
  # INVARIANT: `context` and `inline_context` may never name anything in
  # Profile::SAFETY_SENSITIVE_KEYS. A child's allergies, medical conditions,
  # emergency notes, and emergency contacts do not go to OpenAI. This is
  # enforced by spec/services/suggestions/registry_spec.rb — if you are here to
  # add a key and that spec is in your way, the spec is right and you are wrong.
  module Registry
    # Inline context values come from the client (used only where the record
    # doesn't exist yet, e.g. mid-onboarding). The server still decides WHICH
    # keys are legal; this caps how long each value may be.
    INLINE_VALUE_MAX_CHARS = 60

    FIELDS = {
      # About Me on a saved communicator profile — profiles.bio, public.
      "profile_about_me" => {
        subject: "Profile",
        context: %i[name age_band aac_level glp_stage interests],
        inline_context: [],
        template: :about_me,
        count: 3,
        max_chars: 180,
      },
      # Same field during the MySpeak wizard, where no Profile exists yet. Only
      # the name is available, so suggestions are thinner here by design.
      "onboarding_about_me" => {
        subject: nil,
        context: [],
        inline_context: %i[name],
        template: :about_me,
        count: 3,
        max_chars: 180,
      },
    }.freeze

    def self.fetch(field_key)
      FIELDS[field_key.to_s]
    end
  end
end
