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

  # Words chosen so we can predict the part-of-speech banding: a pronoun, two
  # words AacWordCategorizer::OVERRIDES recategorises ("stop" and "more" come
  # back from models as a verb and a determiner), and a block of plain verbs.
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
        { "word" => "I",     "frequency" => "high", "part_of_speech" => "pronoun" },
        { "word" => "want",  "frequency" => "high", "part_of_speech" => "verb" },
        { "word" => "help",  "frequency" => "high", "part_of_speech" => "verb" },
        { "word" => "more",  "frequency" => "high", "part_of_speech" => "determiner" },
        { "word" => "stop",  "frequency" => "high", "part_of_speech" => "verb" },
        { "word" => "go",    "frequency" => "high", "part_of_speech" => "verb" },
        { "word" => "yes",   "frequency" => "high", "part_of_speech" => "interjection" },
        { "word" => "no",    "frequency" => "high", "part_of_speech" => "interjection" },
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

  it "groups tiles into Modified Fitzgerald bands rather than the AI's raw order" do
    board.format_board_with_ai
    board.reload

    # pronoun | social | important_function | verb. "more" and "yes" are social
    # and "stop" is important_function via AacWordCategorizer::OVERRIDES, even
    # though the payload above called them a determiner, an interjection and a
    # verb. Within each band the model's own order survives — the sort is stable.
    expect(board.board_images.order(:position).pluck(:display_label))
      .to eq(%w[I more yes stop no want help go])
  end

  it "sorts a door tile after every word band" do
    page = FactoryBot.create(:board, user: user, name: "Food")
    door = board.board_images.find_by(label: "want")
    door.update!(predictive_board_id: page.id)
    door.update!(data: (door.data || {}).merge("mute_name" => true))

    board.format_board_with_ai
    board.reload

    expect(board.board_images.order(:position).last.label).to eq("want")
  end

  it "lays every tile out at exactly one cell on every screen" do
    board.format_board_with_ai
    board.reload

    %w[sm md lg].each do |screen|
      expect(board.layout[screen].map { |c| [c["w"], c["h"]] }.uniq).to eq([[1, 1]])
      board.board_images.each do |bi|
        expect(bi.layout[screen].values_at("w", "h")).to eq([1, 1]), "#{bi.label} is multi-cell on #{screen}"
      end
    end
  end

  # The live failure this fixes: AiBoardFormatter was allowed "up to 2" tiles at
  # [2,1], which put a 48-tile / 8-column board on 7 rows instead of 6. Because
  # `rows_for_screen_size` is `max(y + h)`, that extra row silently defeated the
  # board's `settings["disable_scroll"]` on the frontend.
  it "uses no more rows than the tile count needs" do
    board.format_board_with_ai
    board.reload

    expect(board.rows_for_screen_size("lg")).to eq((words.length / 6.0).ceil)
  end

  it "flattens tiles that are already multi-cell (regression)" do
    wide = board.board_images.find_by(label: "help")
    wide.layout = wide.layout.transform_values { |cell| cell.merge("w" => 2, "h" => 2) }
    wide.skip_create_voice_audio = true
    wide.save!

    board.format_board_with_ai
    board.reload

    expect(board.board_images.find_by(label: "help").layout["lg"].values_at("w", "h")).to eq([1, 1])
  end

  # Feeding the current w/h back to the model made a wide tile STICKY: every
  # re-run was told the tile was already two cells, so no re-format could ever
  # return the board to a clean grid.
  it "never tells the formatter what size a tile currently is" do
    wide = board.board_images.find_by(label: "help")
    wide.layout = wide.layout.transform_values { |cell| cell.merge("w" => 2) }
    wide.skip_create_voice_audio = true
    wide.save!

    captured = nil
    allow(AiBoardFormatter).to receive(:call) { |**kwargs| captured = kwargs; ai_payload }

    board.format_board_with_ai

    expect(captured[:existing]).to all(satisfy { |entry| !entry.key?(:size) })
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

  describe "part of speech and tile colour" do
    let(:ai_payload) do
      {
        "ordered_words" => [
          { "word" => "no",   "frequency" => "high", "part_of_speech" => "important_function" },
          { "word" => "yes",  "frequency" => "high", "part_of_speech" => "social" },
          { "word" => "stop", "frequency" => "high", "part_of_speech" => "verb" },
        ],
      }
    end

    it "colours a tile from the Modified Fitzgerald Key category it was given" do
      board.format_board_with_ai
      board.reload

      no_tile = board.board_images.find { |bi| bi.label == "no" }
      yes_tile = board.board_images.find { |bi| bi.label == "yes" }

      expect(no_tile.data["part_of_speech"]).to eq("important_function")
      expect(no_tile.data["bg_color"]).to eq(ColorHelper::PRESET_HEX["red"])
      expect(yes_tile.data["bg_color"]).to eq(ColorHelper::PRESET_HEX["pink"])
    end

    # A tile is coloured by the value it was SORTED by, or a red protest word
    # ends up sitting in the verb block painted green.
    it "colours a tile from the corrected category, not the model's answer" do
      board.format_board_with_ai
      board.reload

      stop_tile = board.board_images.find { |bi| bi.label == "stop" }

      expect(stop_tile.data["part_of_speech"]).to eq("important_function")
      expect(stop_tile.data["bg_color"]).to eq(ColorHelper::PRESET_HEX["red"])
    end

    # `images` is a shared library row — one "no" is on boards across unrelated
    # accounts — so a POS this user's layout run guessed must not repaint
    # everyone else's tile.
    it "does not write the AI's part_of_speech back to the shared Image" do
      shared = board.board_images.find { |bi| bi.label == "no" }.image
      shared.update_columns(part_of_speech: "noun")

      expect { board.format_board_with_ai }
        .not_to change { shared.reload.part_of_speech }

      # The tile learned "important_function"; the shared library row did not.
      expect(shared.reload.part_of_speech).to eq("noun")
      expect(board.board_images.find { |bi| bi.label == "no" }.data["part_of_speech"])
        .to eq("important_function")
    end
  end

  # The reported failure, end to end: 48 tiles on 8 columns with
  # settings["disable_scroll"] set. Two [2,1] tiles turned that into 7 rows with
  # two tiles on the last one, and the frontend then unlocked the board and let
  # it scroll rather than squash seven rows below a readable height.
  describe "a full grid whose tile count divides evenly" do
    let(:wide_board) do
      FactoryBot.create(:board, user: user, large_screen_columns: 8,
                                medium_screen_columns: 6, small_screen_columns: 3,
                                settings: { "disable_scroll" => true })
    end
    let(:park_words) do
      %w[yes no stop help more want go look play sit run slide swing climb wait
         watch push pull throw catch hide find laugh share like again not] +
        ["all done"] +
        %w[different tired hot cold fun scared happy sad fast slow here there up
           down ball friend tree water picnic bug]
    end

    before do
      park_words.each do |word|
        bi = FactoryBot.build(:board_image, board: wide_board,
                                            image: FactoryBot.create(:image, user: user, label: word))
        bi.skip_create_voice_audio = true
        bi.save!
      end
      allow(AiBoardFormatter).to receive(:call).and_return(
        "ordered_words" => park_words.map do |word|
          { "word" => word, "frequency" => "high", "part_of_speech" => "verb" }
        end,
      )
    end

    it "uses six full rows and leaves disable_scroll honourable" do
      expect(park_words.length).to eq(48)

      wide_board.format_board_with_ai
      fresh = Board.find(wide_board.id)

      expect(fresh.rows_for_screen_size("lg")).to eq(6)
      expect(fresh.layout["lg"].count { |cell| cell["y"] == 5 }).to eq(8)
      expect(fresh.layout["lg"].map { |cell| [cell["w"], cell["h"]] }.uniq).to eq([[1, 1]])
      expect(fresh.settings["disable_scroll"]).to be(true)
    end
  end
end
