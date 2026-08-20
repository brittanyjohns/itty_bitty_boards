require "rails_helper"

RSpec.describe Etsy::CopyAdvisories do
  def advise(**listing)
    described_class.new({ "title" => "AAC Communication Board Printable, Recess (Digital Download)",
                          "tags" => Array.new(13) { |i| "tag phrase #{i}" } }.merge(listing.stringify_keys))
  end

  it "stays quiet on a full, well-formed listing" do
    expect(advise).not_to be_any
  end

  it "flags unused tag slots" do
    advisories = advise(tags: Array.new(9) { |i| "tag phrase #{i}" }).advisories

    expect(advisories.map(&:key)).to include(:short_tag_set)
    expect(advisories.find { |a| a.key == :short_tag_set }.message).to include("9 of 13")
  end

  # Generation can no longer emit one, but a tag saved before the rule existed
  # is still in the jsonb and still burning a slot.
  it "flags a single-word tag still stored on the listing" do
    advisories = advise(tags: ["aac", "printable"] + Array.new(11) { |i| "tag phrase #{i}" }).advisories

    message = advisories.find { |a| a.key == :single_word_tags }.message
    expect(message).to include("aac", "printable")
  end

  it "flags a title that buries the head term past the first 40 characters" do
    buried = "Recess and Playground Communication Boards for School, AAC Printable"
    expect(advise(title: buried).advisories.map(&:key)).to include(:buried_head_term)
  end

  it "accepts a head term inside the window" do
    expect(advise(title: "AAC Core Words Board, 84-Word Set").advisories.map(&:key))
      .not_to include(:buried_head_term)
  end

  it "says nothing about a title that hasn't been generated yet" do
    expect(advise(title: "").advisories.map(&:key)).not_to include(:buried_head_term)
  end

  it "tolerates a listing hash with nothing in it" do
    expect(described_class.new(nil).advisories.map(&:key)).to eq([:short_tag_set])
  end
end
