# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "printables listing backfill rake tasks", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core Words") }

  def complete_printable(**attrs)
    BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id], **attrs)
  end

  def with_current_gallery(printable)
    BoardPrintable::LISTING_IMAGE_ORDER.each { |v| printable.attach_image!(bytes: "png-#{v}", variant: v) }
    printable
  end

  describe "printables:render_listing_videos" do
    let(:task) { Rake::Task["printables:render_listing_videos"] }

    def run_task
      task.reenable
      task.invoke
    end

    around do |example|
      original = ENV["PUBLISHED_ONLY"]
      example.run
      ENV["PUBLISHED_ONLY"] = original
    end

    before { allow(VideoTranscoder).to receive(:available?).and_return(true) }

    it "enqueues a render for a printable with no video" do
      printable = complete_printable

      expect { run_task }.to change(RenderBoardPrintableListingVideoJob.jobs, :size).by(1)
      expect(RenderBoardPrintableListingVideoJob.jobs.last["args"]).to eq([printable.id])
    end

    # Nothing can re-render a hand-uploaded clip, so replacing it is exactly
    # what the operator who uploaded it did not ask for.
    it "skips a hand-uploaded clip" do
      printable = complete_printable
      printable.attach_video!(bytes: "mp4", duration: 9.0, source: BoardPrintable::VIDEO_MANUAL)

      expect { run_task }.not_to change(RenderBoardPrintableListingVideoJob.jobs, :size)
    end

    it "skips a printable whose rendered video is already current" do
      printable = complete_printable
      printable.attach_video!(bytes: "mp4", duration: 9.0)

      expect { run_task }.not_to change(RenderBoardPrintableListingVideoJob.jobs, :size)
    end

    it "narrows to listed printables under PUBLISHED_ONLY" do
      complete_printable
      listed = complete_printable(etsy_listing_id: 987, etsy_published_at: 1.day.ago)
      ENV["PUBLISHED_ONLY"] = "1"

      expect { run_task }.to change(RenderBoardPrintableListingVideoJob.jobs, :size).by(1)
      expect(RenderBoardPrintableListingVideoJob.jobs.last["args"]).to eq([listed.id])
    end

    # The job checks too and would return immediately, which looks exactly like
    # the task having worked.
    it "aborts rather than enqueueing when ffmpeg is unavailable" do
      complete_printable
      allow(VideoTranscoder).to receive(:available?).and_return(false)

      expect { run_task }.to raise_error(SystemExit)
        .and(not_change(RenderBoardPrintableListingVideoJob.jobs, :size))
    end
  end

  describe "printables:export_listing" do
    let(:task) { Rake::Task["printables:export_listing"] }
    let(:out_dir) { Rails.root.join("tmp", "etsy_exports_spec_#{SecureRandom.hex(4)}") }

    def run_task(printable_id = nil)
      task.reenable
      task.invoke(printable_id)
    end

    around do |example|
      original = ENV["OUT_DIR"]
      ENV["OUT_DIR"] = out_dir.to_s
      example.run
      ENV["OUT_DIR"] = original
      FileUtils.rm_rf(out_dir)
    end

    let(:printable) do
      p = complete_printable(etsy_listing_id: 987, etsy_published_at: 1.day.ago)
      p.update!(listing_copy: {
        "title" => "Core Words Communication Board",
        "description" => "A printable communication board.",
        "tags" => ["aac", "hospital stay"],
        "price_cents" => 450,
      })
      with_current_gallery(p)
    end

    def config_for(p) = JSON.parse(File.read(out_dir.join(p.id.to_s, "listing.json")))

    it "writes a config the printables CLI can read, with every gallery image in rank order" do
      run_task(printable.id.to_s)

      config = config_for(printable)
      expect(config["title"]).to eq("Core Words Communication Board")
      expect(config["tags"]).to eq(["aac", "hospital stay"])
      expect(config["price"]).to eq(4.5)
      expect(config["images"].size).to eq(BoardPrintable::LISTING_IMAGE_ORDER.size)

      # The ARRAY order is what decides Etsy's ranks, and rank 1 is the search
      # thumbnail — so it has to be LISTING_IMAGE_ORDER, not whatever order the
      # blobs happen to come back in.
      expected = BoardPrintable::LISTING_IMAGE_ORDER.map { |v| v.dasherize }
      expect(config["images"].map { |n| n.sub(/\A\d+-/, "").sub(/\.png\z/, "") }).to eq(expected)

      config["images"].each do |name|
        expect(File).to exist(out_dir.join(printable.id.to_s, name))
      end
    end

    # Writing "active" here would be this app activating a listing, which is the
    # thing the drafts-only invariant exists to prevent. Omitting the key leaves
    # the CLI no state to send.
    it "sends no listing state and no download files" do
      run_task(printable.id.to_s)

      config = config_for(printable)
      expect(config).not_to have_key("state")
      expect(config).not_to have_key("files")
      expect(config).not_to have_key("taxonomyId")
    end

    # --replace-images DELETES the listing's photos before uploading, so a
    # partial gallery would take nine good images off and put five back.
    it "refuses a printable whose gallery isn't current" do
      stale = complete_printable(etsy_listing_id: 55, etsy_published_at: 1.day.ago)
      stale.update!(listing_copy: { "title" => "T", "description" => "D", "tags" => [], "price_cents" => 500 })
      stale.attach_image!(bytes: "png", variant: BoardPrintable::LISTING_IMAGE_ORDER.first)

      run_task(stale.id.to_s)

      expect(File).not_to exist(out_dir.join(stale.id.to_s, "listing.json"))
    end

    it "exports every listed printable when given no id" do
      printable
      unlisted = with_current_gallery(complete_printable)
      unlisted.update!(listing_copy: { "title" => "T", "description" => "D", "tags" => [], "price_cents" => 500 })

      run_task

      expect(File).to exist(out_dir.join(printable.id.to_s, "listing.json"))
      # Nothing to push to, so nothing to export.
      expect(File).not_to exist(out_dir.join(unlisted.id.to_s, "listing.json"))
    end

    it "writes nothing to the database" do
      printable

      expect { run_task(printable.id.to_s) }.not_to change { printable.reload.attributes }
    end
  end
end
