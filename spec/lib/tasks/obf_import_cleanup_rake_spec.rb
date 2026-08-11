require "rails_helper"
require "rake"

RSpec.describe "obf_import rake tasks", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:user) { create(:user) }

  def run(**env)
    env.each { |k, v| ENV[k.to_s] = v.to_s }
    task = Rake::Task["obf_import:cleanup"]
    task.reenable
    task.invoke
  ensure
    env.each_key { |k| ENV.delete(k.to_s) }
  end

  def silence_stream
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  # These stand in for rows the OLD job left behind: it wrote the retired
  # `importing` status and could save a board with no slug at all.
  def stuck_board(name:, tiles: 0, slug: "stuck-#{SecureRandom.hex(4)}")
    board = create(:board, user: user, name: name, slug: slug)
    board.update_column(:status, "importing")
    tiles.times do
      board.board_images.create!(image: create(:image, user_id: user.id),
                                 voice: "polly:kevin", skip_create_voice_audio: true)
    end
    board
  end

  describe "the default dry run" do
    it "previews the repair without making it" do
      board = stuck_board(name: "half imported", tiles: 1)

      expect { run }.to output(
        /\[DRY RUN\] board ##{board.id} .* importing -> complete/,
      ).to_stdout

      expect(board.reload.status).to eq("importing")
    end
  end

  describe "with DRY_RUN=false" do
    # It got its content and lost only the final status write.
    it "marks a stuck board that has tiles complete" do
      board = stuck_board(name: "half imported", tiles: 2)

      silence_stream { run(DRY_RUN: false) }

      expect(board.reload.status).to eq("complete")
    end

    # An empty husk from a run that died. Kept, not deleted — it is still the
    # user's board and theirs to remove.
    it "marks an empty stuck board failed without deleting it" do
      board = stuck_board(name: "never got going")

      silence_stream { run(DRY_RUN: false) }

      expect(board.reload.status).to eq("failed")
      expect(Board.exists?(board.id)).to be true
    end

    it "leaves boards in any other status alone" do
      board = create(:board, user: user)
      board.update_column(:status, "complete")

      silence_stream { run(DRY_RUN: false) }

      expect(board.reload.status).to eq("complete")
    end

    # The landmine: `boards.slug` defaults to "" and uniqueness does not skip
    # blanks, so the first blank-slug row blocks every later slug-less save.
    it "backfills a blank slug so it can't block the next board's save" do
      board = create(:board, user: user, name: "Zoo Animals", slug: "zoo-animals")
      board.update_column(:slug, "")

      silence_stream { run(DRY_RUN: false) }

      expect(board.reload.slug).to be_present
    end

    it "gives two blank-slug boards with the same name distinct slugs" do
      first = create(:board, user: user, name: "Snack Time")
      second = create(:board, user: user, name: "Snack Time")
      [first, second].each { |b| b.update_column(:slug, "") }

      silence_stream { run(DRY_RUN: false) }

      expect(first.reload.slug).to be_present
      expect(second.reload.slug).to be_present
      expect(first.slug).not_to eq(second.slug)
    end
  end
end
