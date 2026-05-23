require "rails_helper"
require "rake"

RSpec.describe "core_boards rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["core_boards:seed"] }

  # Run the task, resetting the rake invocation guard so it can be called again.
  def run_task
    task.reenable
    task.invoke
  end

  before do
    # Public/predefined boards are owned by the admin user the task looks up.
    FactoryBot.create(:user, id: User::DEFAULT_ADMIN_ID)
    # part-of-speech classification calls OpenAI on Image creation — stub it.
    allow(AacWordCategorizer).to receive(:categorize).and_return("noun")
    # Tile creation enqueues TTS audio jobs; keep the queue out of the test.
    allow(SaveAudioJob).to receive(:perform_async)
  end

  after do
    %w[TOPICS COUNT AGE_RANGE DRY_RUN].each { |k| ENV.delete(k) }
    task.reenable
  end

  describe "curated topic (Core + Lunch)" do
    before do
      ENV["TOPICS"] = "Lunch"
      run_task
    end

    let(:board) { Board.find_by(name: "Core + Lunch") }

    it "creates a published, predefined public board owned by the admin" do
      expect(board).to be_present
      expect(board.predefined).to be(true)
      expect(board.published).to be(true)
      expect(board.user_id).to eq(User::DEFAULT_ADMIN_ID)
      expect(board.parent).to eq(User.find(User::DEFAULT_ADMIN_ID))
      expect(board.slug).to eq("core-lunch")
      expect(board.voice).to eq("polly:kevin")
      expect(board.tags).to include("core words", "featured")
    end

    it "builds an 8-wide grid with 40 tiles" do
      expect(board.number_of_columns).to eq(8)
      expect(board.large_screen_columns).to eq(8)
      expect(board.board_images.count).to eq(40)
    end

    it "places core words on the left half and topic words on the right half" do
      labels = board.board_images.order(:position).pluck(:label)
      expect(labels[0, 4]).to eq(%w[I want help yes])
      expect(labels[4, 4]).to eq(%w[lunch eat hot cold])
      expect(labels[8]).to eq("you") # next core row starts again at column 0
    end

    it "gives core tiles a black border and leaves topic tiles borderless" do
      core_tile = board.board_images.find_by(position: 0)
      topic_tile = board.board_images.find_by(position: 4)

      expect(core_tile.border_width).to eq(5)
      expect(core_tile.border_color).to eq("#000000")
      expect(topic_tile.border_width).to eq(0)
      expect(topic_tile.border_color).to be_nil
    end

    it "lays tiles out row-major across 8 columns" do
      expect(board.board_images.find_by(position: 0).layout["lg"]).to include("x" => 0, "y" => 0)
      expect(board.board_images.find_by(position: 4).layout["lg"]).to include("x" => 4, "y" => 0)
      expect(board.board_images.find_by(position: 8).layout["lg"]).to include("x" => 0, "y" => 1)
      expect(board.board_images.find_by(position: 39).layout["lg"]).to include("x" => 7, "y" => 4)
    end

    it "records the full word list on the board data" do
      expect(board.data["current_word_list"]).to include("I", "want", "lunch", "all done")
    end
  end

  describe "idempotency" do
    it "does not duplicate a board or its tiles on a second run" do
      ENV["TOPICS"] = "Lunch"
      run_task
      run_task

      boards = Board.where(name: "Core + Lunch")
      expect(boards.count).to eq(1)
      expect(boards.first.board_images.count).to eq(40)
    end
  end

  describe "AI fallback for uncurated topics" do
    let(:ai_words) do
      %w[bed pajamas brush\ teeth book story lamp pillow blanket sleep dream
         night quiet hug kiss tired yawn dark cozy snore rest]
    end

    before do
      allow_any_instance_of(Board).to receive(:get_words_for_scenario).and_return(ai_words)
      ENV["TOPICS"] = "Bedtime"
      run_task
    end

    it "builds a full board from AI-generated topic words" do
      board = Board.find_by(name: "Core + Bedtime")
      expect(board).to be_present
      expect(board.board_images.count).to eq(40)
      expect(board.tags).to include("bedtime")
      expect(board.board_images.order(:position).pluck(:label)[4]).to eq("bed")
    end
  end

  describe "insufficient topic words" do
    before do
      allow_any_instance_of(Board).to receive(:get_words_for_scenario).and_return(%w[bed book lamp])
      ENV["TOPICS"] = "Bedtime"
      run_task
    end

    it "leaves the board unpublished with no tiles rather than a broken grid" do
      board = Board.find_by(name: "Core + Bedtime")
      expect(board).to be_present
      expect(board.published).to be(false)
      expect(board.board_images.count).to eq(0)
    end
  end

  describe "DRY_RUN" do
    it "writes nothing to the database" do
      ENV["TOPICS"] = "Lunch"
      ENV["DRY_RUN"] = "1"
      run_task

      expect(Board.where(name: "Core + Lunch")).to be_empty
    end
  end

  describe "COUNT" do
    it "creates the first N curated topic boards" do
      ENV["COUNT"] = "2"
      run_task

      expect(Board.where(name: ["Core + Lunch", "Core + Playground"]).count).to eq(2)
      expect(Board.find_by(name: "Core + Swimming")).to be_nil
    end
  end
end
