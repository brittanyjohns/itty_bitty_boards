require "rails_helper"

RSpec.describe KitPages::CopySuggester do
  def ai_copy(overrides = {})
    {
      "eyebrow" => "Free classroom kit",
      "title" => "The at-school communication kit",
      "subhead" => "Print it once and put it where the talking happens.",
      "items" => [
        { "title" => "Core word poster", "description" => "One page, 36 words." },
        { "title" => "Snack board", "description" => "For the table." },
        { "title" => "Playground page", "description" => "For outside." },
      ],
      "closing" => {
        "heading" => "Make it yours",
        "body" => "Build the same board in the app.",
        "cta_label" => "Start free",
        "cta_path" => "/sign-up",
      },
    }.merge(overrides).to_json
  end

  def stub_ai(content)
    allow_any_instance_of(OpenAiClient).to receive(:create_chat)
      .and_return({ role: "assistant", content: content })
  end

  before { stub_ai(ai_copy) }

  def suggest(**overrides)
    described_class.new(**{ slug: "at-school" }.merge(overrides)).call
  end

  describe "#call" do
    it "returns the whole page" do
      copy = suggest

      expect(copy[:eyebrow]).to eq("Free classroom kit")
      expect(copy[:title]).to eq("The at-school communication kit")
      expect(copy[:subhead]).to eq("Print it once and put it where the talking happens.")
      expect(copy[:items].first).to eq({ "title" => "Core word poster", "description" => "One page, 36 words." })
      expect(copy[:closing]["heading"]).to eq("Make it yours")
    end

    it "works from the slug alone, so the button still helps before a printable is chosen" do
      expect { suggest(printable: nil) }.not_to raise_error
    end

    it "refuses to run with nothing to work from" do
      expect { described_class.new(slug: "", title: "", printable: nil).call }
        .to raise_error(described_class::GenerationError, /pick a printable/)
    end

    it "raises when the response isn't parseable" do
      stub_ai("not json at all")
      expect { suggest }.to raise_error(described_class::GenerationError, /Failed to parse/)
    end

    it "raises when the response is a JSON array rather than an object" do
      stub_ai("[]")
      expect { suggest }.to raise_error(described_class::GenerationError, /not an object/)
    end

    it "raises when nothing usable comes back" do
      stub_ai({ "eyebrow" => "Free kit" }.to_json)
      expect { suggest }.to raise_error(described_class::GenerationError, /nothing usable/)
    end
  end

  describe "cleanup" do
    it "strips HTML, because the frontend renders these as text" do
      stub_ai(ai_copy("title" => "<h1>The at-school kit</h1>"))

      expect(suggest[:title]).to eq("The at-school kit")
    end

    it "truncates every runaway field" do
      stub_ai(ai_copy(
        "eyebrow" => "word " * 40,
        "title" => "word " * 60,
        "subhead" => "word " * 120,
      ))
      copy = suggest

      expect(copy[:eyebrow].length).to be <= described_class::MAX_EYEBROW_LENGTH
      expect(copy[:title].length).to be <= described_class::MAX_TITLE_LENGTH
      expect(copy[:subhead].length).to be <= described_class::MAX_SUBHEAD_LENGTH
    end

    it "caps the number of items" do
      many = Array.new(12) { |i| { "title" => "Item #{i}", "description" => "A page." } }
      stub_ai(ai_copy("items" => many))

      expect(suggest[:items].length).to eq(described_class::MAX_ITEMS)
    end

    it "drops an item with neither a title nor a description" do
      stub_ai(ai_copy("items" => [{ "title" => "", "description" => "" }, { "title" => "Real", "description" => "Yes." }]))

      expect(suggest[:items]).to eq([{ "title" => "Real", "description" => "Yes." }])
    end

    it "ignores an items entry that isn't an object" do
      stub_ai(ai_copy("items" => ["just a string", { "title" => "Real", "description" => "Yes." }]))

      expect(suggest[:items]).to eq([{ "title" => "Real", "description" => "Yes." }])
    end
  end

  describe "the CTA path" do
    it "keeps a site-relative path" do
      expect(suggest[:closing]["cta_path"]).to eq("/sign-up")
    end

    it "replaces an absolute URL, which would send the visitor off the page" do
      stub_ai(ai_copy("closing" => { "heading" => "Go", "cta_path" => "https://example.com/steal" }))

      expect(suggest[:closing]["cta_path"]).to eq(described_class::DEFAULT_CTA_PATH)
    end

    it "replaces a path that doesn't start with a slash" do
      stub_ai(ai_copy("closing" => { "heading" => "Go", "cta_path" => "sign-up" }))

      expect(suggest[:closing]["cta_path"]).to eq(described_class::DEFAULT_CTA_PATH)
    end

    it "falls back to a default label when the model omits one" do
      stub_ai(ai_copy("closing" => { "heading" => "Go", "cta_label" => "" }))

      expect(suggest[:closing]["cta_label"]).to eq(described_class::DEFAULT_CTA_LABEL)
    end

    it "returns an empty closing when the model omits the block" do
      stub_ai(ai_copy("closing" => nil))

      expect(suggest[:closing]).to eq({})
    end
  end

  describe "what the printable contributes to the prompt" do
    let(:board) { create(:board, name: "At school") }
    let(:printable) do
      BoardPrintable.create!(board: board, status: "complete", page_count: 6,
                             topic: "the school day",
                             listing_copy: { "summary" => "Six pages for the classroom.",
                                             "description" => "INSTANT DOWNLOAD. No sign-in required.",
                                             "tags" => %w[aac classroom] })
    end

    it "feeds the board name, topic, page count, summary and tags" do
      prompt = nil
      allow_any_instance_of(OpenAiClient).to receive(:create_chat) do |client|
        prompt = client.instance_variable_get(:@messages).first[:content]
        { role: "assistant", content: ai_copy }
      end

      described_class.new(slug: "at-school", printable: printable).call

      expect(prompt).to include("At school")
      expect(prompt).to include("the school day")
      expect(prompt).to include("6 pages")
      expect(prompt).to include("Six pages for the classroom.")
      expect(prompt).to include("aac, classroom")
    end

    it "never feeds the Etsy description, which is checkout prose for a paid buyer" do
      prompt = nil
      allow_any_instance_of(OpenAiClient).to receive(:create_chat) do |client|
        prompt = client.instance_variable_get(:@messages).first[:content]
        { role: "assistant", content: ai_copy }
      end

      described_class.new(slug: "at-school", printable: printable).call

      expect(prompt).not_to include("INSTANT DOWNLOAD")
      expect(prompt).not_to include("No sign-in required")
    end
  end
end
