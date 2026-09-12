require "rails_helper"

# The fringe half. Sources are nested one directory per core set, so the job's
# identifier is a path RELATIVE to SEED_DIR — and it is resolved by matching
# against the authored glob as an allowlist, never by interpolating a
# params-derived string into a path. The job re-checks rather than trusting the
# controller, because a job can be replayed from the Sidekiq UI.
RSpec.describe SeedBoardBuilderTemplatesJob do
  let(:job) { described_class.new }

  def fringe_path(name) = job.send(:fringe_path, name)

  describe "#fringe_path" do
    it "resolves a nested source by its relative path" do
      path = fringe_path("core-84/animals.obf")

      expect(path).to be_present
      expect(File.exist?(path)).to be(true)
      expect(JSON.parse(File.read(path))[Boards::FringeTemplates::VARIANT_KEY]).to eq("core-84")
    end

    it "tells the two variants of one category apart" do
      sixty = JSON.parse(File.read(fringe_path("core-60/animals.obf")))
      eighty = JSON.parse(File.read(fringe_path("core-84/animals.obf")))

      expect(sixty["id"]).to eq("fringe:animals")
      expect(eighty["id"]).to eq("fringe:core-84:animals")
    end

    it "refuses a bare basename now that sources are nested" do
      expect(fringe_path("animals.obf")).to be_nil
    end

    it "refuses a traversal attempt" do
      expect(fringe_path("../../../config/database.yml")).to be_nil
      expect(fringe_path("../../../config/database.yml.obf")).to be_nil
      expect(fringe_path("core-60/../../../../etc/passwd.obf")).to be_nil
    end

    it "refuses anything that is not an .obf" do
      expect(fringe_path("core-60/animals.json")).to be_nil
      expect(fringe_path("")).to be_nil
    end
  end

  describe "#perform" do
    it "seeds one named source" do
      User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)

      job.perform("fringe", "core-84/animals.obf")

      board = Boards::FringeTemplates.find("Animals", core_template: "core-84")
      expect(board).to be_present
      expect(board.large_screen_columns).to eq(12)
      expect(board.board_images.count).to eq(60)
    end

    it "writes nothing for a source it cannot resolve" do
      expect { job.perform("fringe", "animals.obf") }.not_to change(Board, :count)
    end
  end
end
