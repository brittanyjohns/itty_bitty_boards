require "rails_helper"

RSpec.describe GenerateBoardJob, type: :job do
  let(:user) { create(:user) }

  describe "scenario word_count fallback when large_screen_columns is 0" do
    # Boards created via api/internal/boards#create historically coerced
    # missing column params to 0. The job's `|| 6` fallback didn't fire on
    # 0 (truthy in Ruby), so word_count became 0 and no words were generated.
    # The fix uses `.to_i.positive?`. Lock that in.
    let(:board) do
      create(
        :board,
        user: user,
        name: "Zero-cols Scenario",
        board_type: "scenario",
        large_screen_columns: 0,
        medium_screen_columns: 0,
        small_screen_columns: 0,
      )
    end

    before do
      allow_any_instance_of(Board).to receive(:find_or_create_images_from_word_list)
      allow_any_instance_of(Board).to receive(:reset_layouts)
      allow_any_instance_of(Board).to receive(:generate_previews)
      # Avoid the literal 2-second sleep in the job for fast tests.
      allow_any_instance_of(described_class).to receive(:sleep)
    end

    it "uses 6 as the column fallback (-> 24 words) when word_count is out of bounds" do
      expect(board).to receive(:get_words_for_scenario)
        .with("ordering coffee", "10-15", 24, profile: nil)
        .and_return(["hi"])
      allow(Board).to receive(:find_by).with(id: board.id).and_return(board)

      described_class.new.perform(
        board.id,
        "scenario",
        { "topic" => "ordering coffee", "age_range" => "10-15", "word_count" => 0 },
      )
    end
  end

  describe "scenario word_count fallback uses positive large_screen_columns" do
    let(:board) do
      create(
        :board,
        user: user,
        name: "Five-cols Scenario",
        board_type: "scenario",
        large_screen_columns: 5,
      )
    end

    before do
      allow_any_instance_of(Board).to receive(:find_or_create_images_from_word_list)
      allow_any_instance_of(Board).to receive(:reset_layouts)
      allow_any_instance_of(Board).to receive(:generate_previews)
      allow_any_instance_of(described_class).to receive(:sleep)
    end

    it "uses the board's large_screen_columns (-> 20 words)" do
      expect(board).to receive(:get_words_for_scenario)
        .with("ordering coffee", "10-15", 20, profile: nil)
        .and_return(["hi"])
      allow(Board).to receive(:find_by).with(id: board.id).and_return(board)

      described_class.new.perform(
        board.id,
        "scenario",
        { "topic" => "ordering coffee", "age_range" => "10-15", "word_count" => 0 },
      )
    end
  end

  describe "scenario communicator profile forwarding" do
    let(:board) do
      create(:board, user: user, name: "Profiled Scenario", board_type: "scenario", large_screen_columns: 5)
    end

    before do
      allow_any_instance_of(Board).to receive(:find_or_create_images_from_word_list)
      allow_any_instance_of(Board).to receive(:reset_layouts)
      allow_any_instance_of(Board).to receive(:generate_previews)
      allow_any_instance_of(described_class).to receive(:sleep)
    end

    it "builds a CommunicatorProfile from the options hash and forwards it" do
      expect(board).to receive(:get_words_for_scenario) do |_topic, _age_range, _word_count, profile:|
        expect(profile).to be_a(CommunicatorProfile)
        expect(profile.aac_level).to eq("emerging")
        expect(profile.age_band).to eq("4-6")
        ["hi"]
      end
      allow(Board).to receive(:find_by).with(id: board.id).and_return(board)

      described_class.new.perform(
        board.id,
        "scenario",
        {
          "topic" => "doctor visit",
          "age_range" => "10-15",
          "word_count" => 20,
          "profile" => { "age" => "4", "aac_level" => "emerging" },
        },
      )
    end
  end

  describe "default creation with both seed words and a topic" do
    let(:board) do
      create(:board, user: user, name: "Morning Routine", board_type: "default", large_screen_columns: 5)
    end

    before do
      allow_any_instance_of(Board).to receive(:find_or_create_images_from_word_list)
      allow_any_instance_of(Board).to receive(:reset_layouts)
      allow_any_instance_of(Board).to receive(:generate_previews)
      allow_any_instance_of(described_class).to receive(:sleep)
    end

    it "combines the seed word_list with topic-generated words (deduped)" do
      allow(Board).to receive(:find_by).with(id: board.id).and_return(board)
      expect(board).to receive(:get_words_for_scenario)
        .with("morning routine", nil, 5, profile: nil)
        .and_return(%w[wake eat])

      captured = nil
      allow(board).to receive(:find_or_create_images_from_word_list) { |w| captured = w }

      described_class.new.perform(
        board.id,
        "default",
        { "topic" => "morning routine", "word_list" => %w[wake brush], "word_count" => 5 },
      )

      expect(captured).to eq(%w[wake brush eat])
    end

    it "uses the seed words alone when no topic is given" do
      allow(Board).to receive(:find_by).with(id: board.id).and_return(board)
      expect(board).not_to receive(:get_words_for_scenario)

      captured = nil
      allow(board).to receive(:find_or_create_images_from_word_list) { |w| captured = w }

      described_class.new.perform(
        board.id,
        "default",
        { "word_list" => %w[apple banana], "word_count" => 5 },
      )

      expect(captured).to eq(%w[apple banana])
    end
  end
end
