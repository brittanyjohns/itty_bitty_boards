require "rails_helper"

# WordEventsHelper is a model concern mixed into ChildAccount; exercised here
# through a ChildAccount and its word_events association.
RSpec.describe WordEventsHelper, type: :model do
  let(:user) { create(:user) }
  let(:account) { create(:child_account, user: user) }
  let(:range) { 90.days.ago.beginning_of_day..Time.current }

  def add_event(attrs = {})
    create(:word_event, { user: user, child_account: account }.merge(attrs))
  end

  describe "#heat_map" do
    it "with no range groups every word event by day" do
      add_event(timestamp: 1.day.ago)
      add_event(timestamp: 1.day.ago)
      add_event(timestamp: 300.days.ago)

      expect(account.heat_map.sum { |entry| entry[:count] }).to eq(3)
    end

    it "with a range only counts events inside it" do
      add_event(timestamp: 1.day.ago)
      add_event(timestamp: 1.day.ago)
      add_event(timestamp: 300.days.ago)

      expect(account.heat_map(range).sum { |entry| entry[:count] }).to eq(2)
    end
  end

  describe "#word_events_summary" do
    it "computes totals over the range" do
      add_event(word: "hello", timestamp: 1.day.ago)
      add_event(word: "hello", timestamp: 1.day.ago)
      add_event(word: "bye", timestamp: 2.days.ago)
      add_event(word: "stale", timestamp: 300.days.ago)

      summary = account.word_events_summary(range)

      expect(summary[:total_events]).to eq(3)
      expect(summary[:unique_words]).to eq(2)
      expect(summary[:active_days]).to eq(2)
      expect(summary[:most_active_day][:count]).to eq(2)
      expect(summary[:avg_per_active_day]).to eq(1.5)
      expect(summary[:top_word]).to eq(word: "hello", count: 2)
    end

    it "returns zeroed metrics when there are no events in range" do
      summary = account.word_events_summary(range)

      expect(summary[:total_events]).to eq(0)
      expect(summary[:active_days]).to eq(0)
      expect(summary[:avg_per_active_day]).to eq(0)
      expect(summary[:most_active_day]).to be_nil
      expect(summary[:top_word]).to be_nil
    end
  end

  describe "#part_of_speech_breakdown" do
    it "counts events grouped by the linked image's part of speech" do
      noun = create(:image).tap { |i| i.update_columns(part_of_speech: "noun") }
      verb = create(:image).tap { |i| i.update_columns(part_of_speech: "verb") }
      add_event(image: noun, timestamp: 1.day.ago)
      add_event(image: noun, timestamp: 1.day.ago)
      add_event(image: verb, timestamp: 1.day.ago)
      add_event(image: nil, timestamp: 1.day.ago)

      expect(account.part_of_speech_breakdown(range)).to eq([
        { label: "noun", count: 2 },
        { label: "verb", count: 1 },
      ])
    end
  end
end
