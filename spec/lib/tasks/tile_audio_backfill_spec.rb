# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "tile_audio rake tasks", type: :task do
  ENV_KEYS = %w[APPLY ENQUEUE LIMIT SAMPLE BOARD_ID USER_ID ADMIN_BUILT].freeze

  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  around do |example|
    original = ENV.to_hash.slice(*ENV_KEYS)
    ENV_KEYS.each { |k| ENV.delete(k) }
    example.run
    ENV_KEYS.each { |k| ENV[k] = original[k] }
  end

  def run_task(name)
    task = Rake::Task[name]
    task.reenable
    task.invoke
  end

  let(:user) { create(:user) }
  let(:board) { create(:board, user: user, voice: "polly:kevin") }
  let(:image) { create(:image, label: "hello", user_id: user.id) }

  # The defect's signature: the tile exists, its voice matches the board's, and
  # audio_url was never written because the job couldn't see the row.
  let!(:orphaned_tile) do
    tile = create(:board_image, board: board, image: image, skip_create_voice_audio: true)
    tile.update_columns(audio_url: nil, voice: "polly:kevin")
    tile
  end

  before { SaveAudioJob.clear }

  describe "tile_audio:missing_report" do
    before { allow_any_instance_of(BoardImage).to receive(:audio_url_for_voice).and_return(nil) }

    it "reports the tile and writes nothing" do
      expect { run_task("tile_audio:missing_report") }
        .to output(/Tiles with no audio_url: 1/).to_stdout

      expect(orphaned_tile.reload.audio_url).to be_nil
      expect(SaveAudioJob.jobs).to be_empty
    end

    # The tile's voice matches its board's, so Board#api_view_with_images takes
    # the else branch and never re-enqueues — this one stays mute forever.
    it "counts a voice-matching tile as one that will never self-heal" do
      expect { run_task("tile_audio:missing_report") }
        .to output(/1 will never self-heal/).to_stdout
    end

    it "counts a voice-mismatched tile as self-healing" do
      orphaned_tile.update_columns(voice: "polly:joanna")

      expect { run_task("tile_audio:missing_report") }
        .to output(/0 will never self-heal/).to_stdout
    end

    it "reports nothing once the tile has audio" do
      orphaned_tile.update_columns(audio_url: "https://cdn.example.com/hello_kevin.mp3")

      expect { run_task("tile_audio:missing_report") }
        .to output(/Nothing to backfill/).to_stdout
    end
  end

  describe "tile_audio:backfill" do
    context "when the Image already has a file for the voice" do
      before do
        allow_any_instance_of(BoardImage)
          .to receive(:audio_url_for_voice).and_return("https://cdn.example.com/hello_kevin.mp3")
      end

      it "is a dry run by default" do
        expect { run_task("tile_audio:backfill") }.to output(/Would repair 1 tiles/).to_stdout
        expect(orphaned_tile.reload.audio_url).to be_nil
      end

      it "points the tile at the existing file under APPLY=1, with no Polly work" do
        ENV["APPLY"] = "1"

        expect { run_task("tile_audio:backfill") }.to output(/Repaired 1 tiles/).to_stdout

        expect(orphaned_tile.reload.audio_url).to eq("https://cdn.example.com/hello_kevin.mp3")
        expect(SaveAudioJob.jobs).to be_empty
      end
    end

    context "when no audio file exists for the voice" do
      before { allow_any_instance_of(BoardImage).to receive(:audio_url_for_voice).and_return(nil) }

      it "queues SaveAudioJob under APPLY=1" do
        ENV["APPLY"] = "1"

        expect { run_task("tile_audio:backfill") }.to output(/Queued 1 SaveAudioJob/).to_stdout

        expect(SaveAudioJob.jobs.size).to eq(1)
        expect(SaveAudioJob.jobs.first["args"])
          .to eq([orphaned_tile.image_id, orphaned_tile.voice, orphaned_tile.id])
      end

      it "skips rather than queues Polly work under ENQUEUE=0" do
        ENV["APPLY"] = "1"
        ENV["ENQUEUE"] = "0"

        expect { run_task("tile_audio:backfill") }.to output(/Skipped 1 tiles/).to_stdout
        expect(SaveAudioJob.jobs).to be_empty
      end
    end

    context "with a tile playing a parent's recording" do
      before do
        allow_any_instance_of(BoardImage).to receive(:audio_url_for_voice).and_return(nil)
        orphaned_tile.update_columns(data: { "using_custom_audio" => true })
      end

      # A custom-audio tile with a blank audio_url means the upload failed —
      # a different problem. Pushing it back onto a synthesized voice would
      # silently replace a parent's recording.
      it "is left alone" do
        ENV["APPLY"] = "1"

        expect { run_task("tile_audio:backfill") }.to output(/Repaired 0 tiles/).to_stdout
        expect(SaveAudioJob.jobs).to be_empty
      end
    end

    it "honours LIMIT" do
      allow_any_instance_of(BoardImage).to receive(:audio_url_for_voice).and_return(nil)
      second = create(:board_image, board: board, image: image, skip_create_voice_audio: true)
      second.update_columns(audio_url: nil)
      ENV["APPLY"] = "1"
      ENV["LIMIT"] = "1"

      expect { run_task("tile_audio:backfill") }.to output(/Queued 1 SaveAudioJob/).to_stdout
      expect(SaveAudioJob.jobs.size).to eq(1)
    end
  end
end
