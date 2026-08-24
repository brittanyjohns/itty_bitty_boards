require "rails_helper"

# "Format with AI" permutes a board's tiles. A board that is part of a
# nav-synced set has a strip along its bottom row that is reproduced
# cell-for-cell on every OTHER page of that set — and a format run touches one
# board, so permuting the strip desyncs it from pages nobody asked to change.
#
# Doors were nearly safe already (LINK_BAND sorts them last), but a nav-row WORD
# is correctly not a door and banded off into the content area by its part of
# speech. See Boards::NavRegion.for_board.
RSpec.describe Board, "#format_board_with_ai with a nav region" do
  let(:user) { FactoryBot.create(:user) }
  let(:board) do
    FactoryBot.create(
      :board,
      user: user,
      small_screen_columns: 2,
      medium_screen_columns: 3,
      large_screen_columns: 4,
    )
  end

  # Two content rows, then a nav row of `this | Food | Play | that`.
  let(:content_words) { %w[I more want help go big happy apple] }
  let(:nav_row) { %w[this Food Play that] }

  # update_column bypasses the layout callbacks so the authored cell stays
  # exactly where the test puts it.
  def tile(label, x:, y:, position:, target: nil, data: {})
    image = FactoryBot.create(:image, user: user, label: label)
    bi = FactoryBot.build(:board_image, board: board, image: image, position: position)
    bi.skip_create_voice_audio = true
    bi.save!
    bi.update_columns(label: label, display_label: label, predictive_board_id: target,
                      data: (bi.data || {}).merge(data))
    bi.update_column(:layout, { "lg" => { "i" => bi.id.to_s, "x" => x, "y" => y, "w" => 1, "h" => 1 } })
    bi
  end

  # nav_data: extra jsonb for the nav tiles — the flags a synced CHILD page
  # carries. A set ROOT carries none and is recognised by its pin instead.
  def build_set_page!(nav_data: {})
    content_words.each_with_index do |label, i|
      tile(label, x: i % 4, y: i / 4, position: i)
    end

    nav_row.each_with_index do |label, x|
      target = %w[Food Play].include?(label) ? FactoryBot.create(:board, user: user, name: label).id : nil
      flags = target ? nav_data.slice("nav_tile") : nav_data.slice("nav_word")
      tile(label, x: x, y: 2, position: content_words.length + x, target: target, data: flags)
    end
    board.board_images.reset
  end

  # Scrambles the reading order the way a real run does: `this`/`that` come back
  # as determiners, which bands them into the middle of the content area.
  let(:ai_payload) do
    words = content_words.map do |word|
      { "word" => word, "frequency" => "high", "part_of_speech" => "verb" }
    end
    words + %w[this that].map do |word|
      { "word" => word, "frequency" => "high", "part_of_speech" => "determiner" }
    end
  end

  before do
    allow(AiBoardFormatter).to receive(:call).and_return("ordered_words" => ai_payload)
    allow(SaveAudioJob).to receive(:perform_async)
  end

  def lg_cell(label)
    board.board_images.reload.find { |bi| bi.label == label }.layout["lg"].values_at("x", "y")
  end

  def cell_for(label, screen)
    board.board_images.reload.find { |bi| bi.label == label }.layout[screen].values_at("x", "y")
  end

  context "on a Board Builder root (recognised by its pin, no flags)" do
    before do
      build_set_page!
      board.update_columns(settings: (board.settings || {}).merge("builder_root" => true))
    end

    it "writes every nav tile back at its own lg cell" do
      board.format_board_with_ai

      expect(nav_row.map { |label| lg_cell(label) }).to eq([[0, 2], [1, 2], [2, 2], [3, 2]])
    end

    it "keeps the nav WORDS in the strip rather than banding them into the content" do
      board.format_board_with_ai

      expect(lg_cell("this")).to eq([0, 2])
      expect(lg_cell("that")).to eq([3, 2])
    end

    it "flows the words through the rows above without overlapping the strip" do
      board.format_board_with_ai
      board.reload

      cells = board.board_images.map { |bi| bi.layout["lg"].values_at("x", "y") }
      expect(cells.uniq.length).to eq(cells.length)
      content_cells = board.board_images
        .reject { |bi| nav_row.include?(bi.label) }
        .map { |bi| bi.layout["lg"].values_at("x", "y") }
      expect(content_cells.map(&:last).uniq).to contain_exactly(0, 1)
    end

    it "uses no more rows than the tile count needs" do
      board.format_board_with_ai
      board.reload

      expect(board.rows_for_screen_size("lg")).to eq(3)
    end

    it "keeps the strip bottom-pinned on md and sm, where lg's cells can't apply" do
      board.format_board_with_ai
      board.reload

      %w[md sm].each do |screen|
        rows = board.board_images.map { |bi| bi.layout[screen]["y"].to_i }
        nav_rows = nav_row.map { |label| cell_for(label, screen).last }
        content_rows = board.board_images
          .reject { |bi| nav_row.include?(bi.label) }
          .map { |bi| bi.layout[screen]["y"].to_i }

        expect(nav_rows.min).to be >= content_rows.max,
                                "nav strip wrapped into the content area on #{screen}"
        expect(nav_rows.max).to eq(rows.max)
      end
    end

    it "still lays every tile out at exactly one cell" do
      board.format_board_with_ai
      board.reload

      %w[sm md lg].each do |screen|
        expect(board.board_images.map { |bi| bi.layout[screen].values_at("w", "h") }.uniq).to eq([[1, 1]])
      end
    end

    it "leaves the reading order matching the grid — nav tiles last" do
      board.format_board_with_ai
      board.reload

      expect(board.board_images.order(:position).last(4).map(&:label)).to eq(nav_row)
    end
  end

  context "on a synced child page (recognised by its nav flags, no pin)" do
    before { build_set_page!(nav_data: { "nav_tile" => true, "nav_word" => true }) }

    it "writes every nav tile back at its own lg cell" do
      board.format_board_with_ai

      expect(nav_row.map { |label| lg_cell(label) }).to eq([[0, 2], [1, 2], [2, 2], [3, 2]])
    end
  end

  context "on an ordinary board that merely holds a folder tile" do
    before { build_set_page! }

    it "reserves nothing and permutes every tile (pre-existing behaviour)" do
      expect(Boards::NavRegion.for_board(board)).to be_empty

      board.format_board_with_ai
      board.reload

      # `this`/`that` band as determiners, ahead of the doors — so the authored
      # strip does NOT survive. That is correct here: nothing reproduces this
      # board's bottom row anywhere else.
      expect(board.board_images.order(:position).last(2).map(&:label)).to contain_exactly("Food", "Play")
      expect(lg_cell("that")).not_to eq([3, 2])
    end
  end
end
