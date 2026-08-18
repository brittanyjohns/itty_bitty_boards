require "rails_helper"

RSpec.describe Printables::SlideCopy do
  describe ".hero_headline" do
    it "leads with the topic when the printable has one" do
      expect(described_class.hero_headline(board_count: 3, topic: "the playground"))
        .to eq("Words for the playground")
    end

    it "counts the boards for a set, and says what the set is" do
      expect(described_class.hero_headline(board_count: 6)).to eq("6 linked boards — flips like a book")
    end

    it "doesn't claim a count for a single board" do
      expect(described_class.hero_headline(board_count: 1)).to eq("A printable communication board")
    end
  end

  describe ".hero_count_badge" do
    it "counts boards and names the print versions separately" do
      badge = described_class.hero_count_badge(board_count: 6)

      expect(badge[:count]).to eq("6")
      expect(badge[:label]).to include("LINKED", "BOARDS")
      # Never board_page_count: "18 PAGES" reads as eighteen pages of
      # vocabulary rather than six pages in three print versions.
      expect(badge[:detail]).to eq("COLOUR · LOW-INK · TRIM-READY")
      expect(badge.values.join).not_to include("18")
    end

    it "is absent for a single board, which has no count worth claiming" do
      expect(described_class.hero_count_badge(board_count: 1)).to be_nil
    end
  end

  # Every one of these sits in a fixed-height band on a 1280px slide. Copy that
  # outgrows its band doesn't wrap, it overlaps the next one — and nothing about
  # a rendered PNG makes that obvious until it's on Etsy.
  describe "copy that has to fit its band" do
    it "keeps every bullet inside the length the layout can hold" do
      bullets = described_class.why_choose_bullets +
                described_class.hero_footer_bullets +
                described_class.how_it_works_steps.map { |s| s[:body] }

      expect(bullets.map(&:length)).to all(be <= described_class::MAX_BULLET_LENGTH)
    end

    it "keeps the bullet lists short enough to stack in one strip" do
      expect(described_class.why_choose_bullets.size).to be <= 4
      expect(described_class.hero_footer_bullets.size).to be <= 3
    end

    it "ships exactly four how-it-works steps, one per card in the strip" do
      steps = described_class.how_it_works_steps

      expect(steps.size).to eq(4)
      expect(steps.map { |s| s[:title] }).to all(be_present)
    end
  end

  # The audio companion is the one thing a competitor's AAC printable can't
  # match, so the phrase carrying it has to say what it DOES. "Voice output" is
  # AAC jargon that a parent shopping for their kid doesn't parse.
  describe "the audio companion" do
    it "names the speaking rather than calling it voice output" do
      copy = [
        described_class.audio_companion_badge,
        described_class.audio_companion_headline,
        described_class.how_it_works_headline,
        *described_class.hero_footer_bullets,
        *described_class.why_choose_bullets,
      ].join(" ")

      expect(copy).not_to match(/voice output/i)
      expect(copy).to match(/audio companion/i)
    end

    it "titles the two what's-included slides apart" do
      expect(described_class.whats_included_title).to eq("What's included")
      expect(described_class.whats_included_title(low_ink: true)).to eq("Low-ink version included")
    end
  end

  # The outro sub is rendered one line per clause. Kept short here because the
  # renderer sets each line `white-space: nowrap` — a long clause would run off
  # the frame instead of wrapping.
  it "splits the outro sub into two short, self-contained clauses" do
    lines = described_class.video_outro_sub_lines

    expect(lines.length).to eq(2)
    expect(lines).to all(satisfy { |line| line.length <= 28 })
    expect(lines.join(" ")).to eq("Free audio companion. No app, no sign-in.")
  end

  # The render box's Chrome has no guaranteed colour-emoji font, so an emoji in
  # slide copy ships to Etsy as a tofu box. Icons are inline SVG instead.
  it "carries no emoji or decorative glyphs outside the font's coverage" do
    all_copy = [
      described_class.instant_download_banner,
      described_class.audio_companion_badge,
      described_class.audio_companion_headline,
      described_class.audio_companion_sub,
      described_class.low_ink_headline,
      described_class.founder_greeting,
      described_class.why_choose_title,
      *described_class.founder_paragraphs,
      *described_class.why_choose_bullets,
      *described_class.hero_footer_bullets,
      *described_class.how_it_works_steps.flat_map { |s| [s[:title], s[:body]] },
    ].join(" ")

    expect(all_copy).not_to match(/[\u{1F000}-\u{1FAFF}\u{2190}-\u{27BF}\u{FE0F}]/)
  end
end
