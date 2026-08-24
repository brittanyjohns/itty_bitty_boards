require "rails_helper"

RSpec.describe UtilHelper do
  subject(:helper) { Class.new { include UtilHelper }.new }

  describe "#transform_into_json" do
    # It used to return a JSON *String* on this path, while every caller reads
    # the result by key — so `result["words"]` was a String#[] substring lookup
    # that answered "words" or nil, and the repair never worked for anyone.
    it "returns a Hash for a repairable payload" do
      result = helper.transform_into_json('{"words" => ["apple", "more"]}')

      expect(result).to be_a(Hash)
      expect(result["words"]).to eq(%w[apple more])
    end

    it "returns a Hash untouched" do
      expect(helper.transform_into_json({ "words" => ["a"] })).to eq({ "words" => ["a"] })
    end

    it "files an unparseable list under the key the caller actually reads" do
      result = helper.transform_into_json("apple, banana, more")

      expect(result["words"]).to eq(%w[apple banana more])
    end

    # The fallback key was hardcoded to "next_words", so the word-list path read
    # ["words_phrases"], got nil, and the board was marked status: "error".
    it "honours an explicit fallback_key" do
      result = helper.transform_into_json("apple, banana", fallback_key: "words_phrases")

      expect(result["words_phrases"]).to eq(%w[apple banana])
      expect(result).not_to have_key("next_words")
    end

    it "wraps a bare array under the fallback key" do
      expect(helper.transform_into_json(%w[a b])).to eq({ "words" => %w[a b] })
    end

    it "returns an empty Hash for content it cannot use at all" do
      expect(helper.transform_into_json(nil)).to eq({})
    end
  end
end
