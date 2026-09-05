require "rails_helper"

RSpec.describe EnhanceImageDescriptionJob, type: :job do
  let(:user) { FactoryBot.create(:user) }
  let(:menu) { FactoryBot.create(:menu, user: user) }
  let(:board) do
    FactoryBot.create(:board, user: user, board_type: "menu",
                              parent_type: "Menu", parent_id: menu.id)
  end

  before do
    CreditService.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
  end

  it "refunds the whole spend when vision extraction produces nothing" do
    txn = CreditService.spend!(user, feature_key: "menu_create", amount: 15)
    board.update!(settings: (board.settings || {}).merge(
      "menu_credit" => { "txn_id" => txn.id, "per_image" => 1, "reserved" => 10 },
    ))
    allow_any_instance_of(Menu).to receive(:enhance_image_description).and_return(nil)

    expect {
      described_class.new.perform(menu.id, board.id)
    }.to change { user.reload.plan_credits_balance }.by(15)

    expect(board.reload.status).to eq("error")
  end

  describe "tile layout" do
    # The board is created the way Api::MenusController#create creates it: with
    # guessed 8/6/4 columns, because the real tile count isn't known until the
    # vision result has been parsed. Menu#apply_grid_columns! then resizes it.
    let(:board) do
      FactoryBot.create(:board, user: user, board_type: "menu",
                                large_screen_columns: 8, medium_screen_columns: 6,
                                small_screen_columns: 4,
                                parent_type: "Menu", parent_id: menu.id)
    end

    before do
      menu.docs.create!(user: user)
      allow_any_instance_of(MenuVisionService).to receive(:extract_menu_items)
        .and_return({ "menu_items" => [{ "name" => "cheeseburger",
                                         "image_description" => "A cheeseburger." }] })
      allow_any_instance_of(Menu).to receive(:menu_image_for_vision)
        .and_return("https://example.com/menu.jpg")
      # Stand in for the image build — the layout only cares about tile count.
      allow_any_instance_of(Menu).to receive(:create_images_from_description) do |_m, b|
        16.times { |i| FactoryBot.create(:board_image, board: b, position: i) }
      end
      allow_any_instance_of(Board).to receive(:run_generate_preview_job)
    end

    # Regression: the job used to re-run reset_layouts on the Board instance it
    # loaded up front, which still held the controller's 8/6/4 columns after
    # apply_grid_columns! had narrowed the row to 4/3/2. That wrote tile x
    # values past the board's real width, and react-grid-layout clamps an
    # off-grid tile to the last column and stacks it vertically.
    it "leaves every tile inside the board's own column count" do
      described_class.new.perform(menu.id, board.id)
      board.reload

      expect(board.large_screen_columns).to eq(4)

      %w[lg md sm].each do |screen|
        columns = board.get_number_of_columns(screen).to_i
        extents = board.board_images.map do |bi|
          cell = bi.layout[screen]
          cell["x"].to_i + cell["w"].to_i
        end

        expect(extents.max).to be <= columns,
                               "expected #{screen} tiles within #{columns} columns, " \
                               "widest reached #{extents.max}"
      end
    end

    it "fills the grid left-to-right rather than stacking one column" do
      described_class.new.perform(menu.id, board.id)
      board.reload

      xs = board.board_images.map { |bi| bi.layout["lg"]["x"] }
      expect(xs.uniq.sort).to eq([0, 1, 2, 3])
    end
  end
end
