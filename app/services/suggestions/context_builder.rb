module Suggestions
  # Turns a registry entry + subject record into the plain hash that becomes
  # prompt context. Only allow-listed keys can be produced, by construction:
  # #build iterates the entry's allow-list, never the record's attributes.
  #
  # Blank values are dropped so the prompt never carries empty fields (an empty
  # "interests:" line makes the model invent interests).
  class ContextBuilder
    def self.build(entry, subject: nil, inline: {})
      new(entry, subject: subject, inline: inline).build
    end

    def initialize(entry, subject: nil, inline: {})
      @entry = entry
      @subject = subject
      @inline = (inline || {}).symbolize_keys
    end

    def build
      from_record.merge(from_inline)
    end

    private

    def from_record
      Array(@entry[:context]).each_with_object({}) do |key, acc|
        value = resolve(key)
        acc[key] = value if value.present?
      end
    end

    def from_inline
      Array(@entry[:inline_context]).each_with_object({}) do |key, acc|
        value = @inline[key].to_s.strip.first(Registry::INLINE_VALUE_MAX_CHARS)
        acc[key] = value if value.present?
      end
    end

    # AAC attributes live on ChildAccount#details (jsonb), not on the Profile.
    # `profileable` is the communicator for a MySpeak profile; it can be a User
    # (a user-level public page) or nil (an unclaimed placeholder), and neither
    # carries communicator context.
    def communicator
      return @communicator if defined?(@communicator)

      profileable = @subject.respond_to?(:profileable) ? @subject.profileable : nil
      @communicator = profileable.is_a?(ChildAccount) ? profileable : nil
    end

    def resolve(key)
      case key
      when :name      then communicator&.name
      when :age_band  then communicator&.age_band
      when :aac_level then communicator&.aac_level
      when :glp_stage then communicator&.glp_stage
      when :interests then Array(communicator&.details&.dig("interests")).join(", ")
      end
    end
  end
end
