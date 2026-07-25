require "rails_helper"

RSpec.describe Suggestions::Registry do
  describe "FIELDS" do
    it "registers the two v1 About Me surfaces" do
      expect(described_class::FIELDS.keys).to contain_exactly(
        "profile_about_me", "onboarding_about_me"
      )
    end

    # THE PRIVACY INVARIANT. A context allow-list may never name a safety key.
    # If this fails, someone is about to send a child's medical data to OpenAI.
    it "never allow-lists a safety-sensitive key" do
      sensitive = Profile::SAFETY_SENSITIVE_KEYS.map(&:to_sym)

      described_class::FIELDS.each do |field_key, entry|
        allow_listed = Array(entry[:context]) + Array(entry[:inline_context])
        expect(allow_listed & sensitive).to be_empty,
          "#{field_key} allow-lists sensitive keys: #{(allow_listed & sensitive).inspect}"
      end
    end

    it "gives every entry a template, a count, and a character cap" do
      described_class::FIELDS.each do |field_key, entry|
        expect(entry[:template]).to be_present, "#{field_key} has no template"
        expect(entry[:count]).to be > 0
        expect(entry[:max_chars]).to be > 0
      end
    end
  end

  describe ".fetch" do
    it "returns the entry for a known key" do
      expect(described_class.fetch("profile_about_me")).to include(template: :about_me)
    end

    it "returns nil for an unknown key" do
      expect(described_class.fetch("not_a_field")).to be_nil
    end
  end
end
