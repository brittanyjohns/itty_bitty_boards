require "rails_helper"

RSpec.describe Board, "#format_board_with_ai", type: :model do
  let(:user) { FactoryBot.create(:user) }
  let(:board) do
    FactoryBot.create(
      :board,
      user: user,
      small_screen_columns: 3,
      medium_screen_columns: 4,
      large_screen_columns: 6,
    )
  end

  # Words chosen so we can predict the AAC ordering used by the stub.
  let(:words) { %w[I want help more stop go yes no] }

  let!(:board_images) do
    words.map do |word|
      image = FactoryBot.create(:image, user: user, label: word)
      bi = FactoryBot.build(:board_image, board: board, image: image)
      bi.skip_create_voice_audio = true
      bi.save!
      bi
    end
  end

  let(:ai_payload) do
    {
      "ordered_words" => [
        { "word" => "I",     "size" => [1, 1], "frequency" => "high", "part_of_speech" => "pronoun" },
        { "word" => "want",  "size" => [2, 1], "frequency" => "high", "part_of_speech" => "verb" },
        { "word" => "help",  "size" => [2, 1], "frequency" => "high", "part_of_speech" => "verb" },
        { "word" => "more",  "size" => [1, 1], "frequency" => "high", "part_of_speech" => "determiner" },
        { "word" => "stop",  "size" => [1, 1], "frequency" => "high", "part_of_speech" => "verb" },
        { "word" => "go",    "size" => [1, 1], "frequency" => "high", "part_of_speech" => "verb" },
        { "word" => "yes",   "size" => [1, 1], "frequency" => "high", "part_of_speech" => "interjection" },
        { "word" => "no",    "size" => [1, 1], "frequency" => "high", "part_of_speech" => "interjection" },
      ],
      "personable_explanation" => "Friendly summary.",
      "professional_explanation" => "AAC reasoning.",
    }
  end

  before do
    allow(AiBoardFormatter).to receive(:call).and_return(ai_payload)
    allow(SaveAudioJob).to receive(:perform_async)
  end

  def cells_for(layout_array)
    layout_array.flat_map do |item|
      w = item["w"].to_i
      h = item["h"].to_i
      (0...w).flat_map { |dx| (0...h).map { |dy| [item["x"].to_i + dx, item["y"].to_i + dy] } }
    end
  end

  it "places every board_image exactly once on every screen with no overlapping cells" do
    board.format_board_with_ai
    board.reload

    %w[sm md lg].each do |screen|
      layout = board.layout[screen]
      expect(layout).to be_an(Array), "expected board.layout[#{screen.inspect}] to be an Array"
      expect(layout.length).to eq(words.length), "wrong tile count for #{screen}"

      cells = cells_for(layout)
      expect(cells.length).to eq(cells.uniq.length), "overlapping cells in #{screen}: #{cells.tally.select { |_, n| n > 1 }}"
    end
  end

  it "keeps board_image.layout in lockstep with board.layout for every screen" do
    board.format_board_with_ai
    board.reload

    %w[sm md lg].each do |screen|
      indexed = board.layout[screen].index_by { |cell| cell["i"] }
      board.board_images.each do |bi|
        per_image = bi.layout[screen]
        expect(per_image).to be_present, "#{bi.label} missing layout for #{screen}"
        expect(per_image.slice("x", "y", "w", "h", "i")).to eq(indexed[bi.id.to_s])
      end
    end
  end

  it "sets board_image#position to match the AI ordering" do
    board.format_board_with_ai
    board.reload

    expect(board.board_images.order(:position).pluck(:label)).to eq(words)
  end

  it "does not place a w=2 tile so it overlaps the previous tile (regression)" do
    board.format_board_with_ai
    board.reload

    # On lg (6 cols): I(1) at (0,0), want(2) at (1,0), help(2) at (3,0),
    # more(1) at (5,0), stop(1) wraps to (0,1), etc. No overlap.
    lg = board.layout["lg"]
    want = lg.find { |c| c["i"] == board.board_images.find_by(label: "want").id.to_s }
    help = lg.find { |c| c["i"] == board.board_images.find_by(label: "help").id.to_s }

    expect(want["w"]).to eq(2)
    expect(help["w"]).to eq(2)
    expect(want["x"] + want["w"]).to be <= help["x"]
  end

  it "wraps a w=2 tile to the next row when it would not fit on the current row" do
    # Force small column count so wrapping is deterministic.
    board.update!(large_screen_columns: 3)

    board.format_board_with_ai
    board.reload

    lg = board.layout["lg"]
    # 3 columns: I(1) at (0,0), want(2) at (1,0). help(2) can't fit at (?,0) — wraps to (0,1).
    help = lg.find { |c| c["i"] == board.board_images.find_by(label: "help").id.to_s }
    expect(help["y"]).to be >= 1
    expect(help["x"]).to eq(0)
  end

  it "writes the explanation fields and seeds description when blank" do
    board.update!(description: nil)
    board.format_board_with_ai
    board.reload

    expect(board.data["personable_explanation"]).to eq("Friendly summary.")
    expect(board.data["professional_explanation"]).to eq("AAC reasoning.")
    expect(board.description).to include("Friendly summary.").and include("AAC reasoning.")
  end

  it "preserves existing description if already set" do
    board.update!(description: "Keep me.")
    board.format_board_with_ai
    board.reload

    expect(board.description).to eq("Keep me.")
  end

  it "appends any board_image dropped by the AI so no tile is lost" do
    short_payload = ai_payload.deep_dup
    short_payload["ordered_words"] = short_payload["ordered_words"].first(5)
    allow(AiBoardFormatter).to receive(:call).and_return(short_payload)

    board.format_board_with_ai
    board.reload

    expect(board.board_images.count).to eq(words.length)
    %w[sm md lg].each do |screen|
      expect(board.layout[screen].length).to eq(words.length)
    end
  end

  it "returns self without raising when AI payload is blank" do
    allow(AiBoardFormatter).to receive(:call).and_return(nil)

    expect { board.format_board_with_ai }.not_to raise_error
  end

  it "is a no-op when the board has no images" do
    empty_board = FactoryBot.create(:board, user: user)
    expect { empty_board.format_board_with_ai }.not_to raise_error
    expect(empty_board.layout || {}).to satisfy { |h| h["lg"].blank? }
  end
end
