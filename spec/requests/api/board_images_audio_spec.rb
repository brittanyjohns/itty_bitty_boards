require "rails_helper"

# Tile audio: recording/uploading a clip, picking which file plays, and
# resetting back to the board's voice.
#
# The load-bearing rule across all three is the custom-audio flag
# (`data["using_custom_audio"]`). Board#api_view_with_images stops re-resolving
# a flagged tile to the board's voice, so a tile left flagged while playing a
# TTS file can never be pulled back — every path that changes what plays has to
# set or clear it.
RSpec.describe "API::BoardImages audio", type: :request do
  let!(:user)        { create(:user) }
  let!(:board)       { create(:board, user: user, voice: "polly:kevin") }
  let!(:image)       { create(:image, label: "juice") }
  let!(:board_image) { create(:board_image, board: board, image: image) }

  def upload_file(content_type: "audio/mpeg", filename: "sample.mp3")
    Rack::Test::UploadedFile.new(
      Rails.root.join("spec/fixtures/files/sample.mp3"), content_type, false, original_filename: filename
    )
  end

  # The response's entry for one of the tile's audio files. `current` is the
  # assertion to make about what plays — never compare URL strings, since the
  # Disk service signs them and the same blob yields a different string on
  # every call.
  def response_audio_file(attachment)
    JSON.parse(response.body)["audio_files"].find { |f| f["id"] == attachment.id }
  end

  def attach_voice_file(record, filename)
    record.audio_files.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/sample.mp3")),
      filename: filename,
      content_type: "audio/mpeg",
    )
    record.reload.audio_files_attachments.order(:id).last
  end

  describe "POST /api/board_images/:id/upload_audio" do
    it "attaches the clip, flags the tile custom, and queues the conversion" do
      expect(ProcessCustomAudioJob).to receive(:perform_async).with(board_image.id, kind_of(Integer))

      post "/api/board_images/#{board_image.id}/upload_audio",
           params: { audio_file: upload_file },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      board_image.reload
      expect(board_image.audio_files.count).to eq(1)
      expect(board_image.data["using_custom_audio"]).to be(true)
      expect(board_image.voice).to eq(BoardImage::CUSTOM_VOICE)
      expect(board_image.audio_url).to be_present
      expect(JSON.parse(response.body)["using_custom_audio"]).to be(true)
    end

    it "keeps the file extension so the clip stays playable" do
      allow(ProcessCustomAudioJob).to receive(:perform_async)

      post "/api/board_images/#{board_image.id}/upload_audio",
           params: { audio_file: upload_file },
           headers: auth_headers(user)

      filename = board_image.reload.audio_files.first.blob.filename.to_s
      expect(filename).to end_with(".mp3")
      expect(filename).to include("custom")
    end

    it "rejects a missing file with 422 and attaches nothing" do
      post "/api/board_images/#{board_image.id}/upload_audio", headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("audio_required")
      expect(board_image.reload.audio_files.count).to eq(0)
    end

    it "rejects a non-audio file with 422" do
      post "/api/board_images/#{board_image.id}/upload_audio",
           params: { audio_file: upload_file(content_type: "application/x-msdownload", filename: "x.exe") },
           headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("invalid_audio_type")
      expect(board_image.reload.audio_files.count).to eq(0)
    end

    it "rejects a file over the size cap with 422" do
      stub_const("BoardImage::MAX_AUDIO_BYTES", 1)

      post "/api/board_images/#{board_image.id}/upload_audio",
           params: { audio_file: upload_file },
           headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("audio_too_large")
    end

    context "when ffmpeg is unavailable" do
      before do
        AudioTranscoder.reset_availability!
        allow(AudioTranscoder).to receive(:available?).and_return(false)
      end

      after { AudioTranscoder.reset_availability! }

      it "refuses webm, which iPad Safari cannot play and we cannot convert" do
        post "/api/board_images/#{board_image.id}/upload_audio",
             params: { audio_file: upload_file(content_type: "audio/webm", filename: "recording.webm") },
             headers: auth_headers(user)

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to eq("invalid_audio_type")
      end
    end

    context "when ffmpeg is available" do
      before do
        AudioTranscoder.reset_availability!
        allow(AudioTranscoder).to receive(:available?).and_return(true)
        allow(ProcessCustomAudioJob).to receive(:perform_async)
      end

      after { AudioTranscoder.reset_availability! }

      it "accepts a browser webm recording for conversion" do
        post "/api/board_images/#{board_image.id}/upload_audio",
             params: { audio_file: upload_file(content_type: "audio/webm", filename: "recording.webm") },
             headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(board_image.reload.audio_files.count).to eq(1)
      end
    end
  end

  describe "POST /api/board_images/:id/set_current_audio" do
    it "resolves the URL from the file id rather than trusting the client" do
      attachment = attach_voice_file(image, "juice_polly_kevin.mp3")

      post "/api/board_images/#{board_image.id}/set_current_audio",
           params: { audio_file_id: attachment.id },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response_audio_file(attachment)["current"]).to be(true)
      expect(board_image.reload.audio_url).to be_present
      expect(board_image.voice).to eq("polly:kevin")
    end

    it "refuses an arbitrary URL — a published tile must not play any host's file" do
      post "/api/board_images/#{board_image.id}/set_current_audio",
           params: { board_image: { audio_url: "https://evil.example/pwn.mp3", voice: "alloy" } },
           headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("audio_file_not_found")
      expect(board_image.reload.audio_url).not_to eq("https://evil.example/pwn.mp3")
    end

    it "refuses a file belonging to someone else's image" do
      other_image = create(:image, label: "water")
      attachment = attach_voice_file(other_image, "water_polly_kevin.mp3")

      post "/api/board_images/#{board_image.id}/set_current_audio",
           params: { audio_file_id: attachment.id },
           headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "clears the custom flag when a synthesized voice is chosen" do
      attachment = attach_voice_file(image, "juice_polly_kevin.mp3")
      board_image.audio_files.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/sample.mp3")),
        filename: "word-custom-010125000000-abc123.mp3", content_type: "audio/mpeg",
      )
      board_image.reload.set_custom_audio!("https://cdn.example/custom.mp3")

      post "/api/board_images/#{board_image.id}/set_current_audio",
           params: { audio_file_id: attachment.id },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(board_image.reload.using_custom_audio?).to be(false)
      expect(board_image.voice).to eq("polly:kevin")
    end

    it "re-flags the tile custom when the recording is chosen again" do
      board_image.audio_files.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/sample.mp3")),
        filename: "word-custom-010125000000-abc123.mp3", content_type: "audio/mpeg",
      )
      attachment = board_image.reload.audio_files_attachments.order(:id).last

      post "/api/board_images/#{board_image.id}/set_current_audio",
           params: { audio_file_id: attachment.id },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(board_image.reload.using_custom_audio?).to be(true)
      expect(board_image.voice).to eq(BoardImage::CUSTOM_VOICE)
    end
  end

  # create_audio lives on the images controller but writes the tile's voice
  # and audio_url and spends on the TTS provider, so it needs the same
  # ownership scope as the rest of the audio surface.
  describe "POST /api/images/:id/create_audio" do
    it "refuses a board image the caller does not own" do
      other_board_image = create(:board_image, board: create(:board, user: create(:user)))
      original_voice = other_board_image.voice

      post "/api/images/#{other_board_image.image_id}/create_audio",
           params: { board_image_id: other_board_image.id, voice: "polly:kevin" },
           headers: auth_headers(user)

      expect(response).to have_http_status(:not_found)
      expect(other_board_image.reload.voice).to eq(original_voice)
    end

    it "lets the owner generate audio for their own tile" do
      post "/api/images/#{board_image.image_id}/create_audio",
           params: { board_image_id: board_image.id, voice: "polly:kevin" },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/board_images/:id/reset_audio" do
    before do
      board_image.audio_files.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/sample.mp3")),
        filename: "word-custom-010125000000-abc123.mp3", content_type: "audio/mpeg",
      )
      board_image.reload.set_custom_audio!("https://cdn.example/custom.mp3")
    end

    it "points the tile back at the board voice's file" do
      attachment = attach_voice_file(image, "juice_polly_kevin.mp3")
      # find_audio_for_voice short-circuits in the test env, so the lookup it
      # would do against S3 filenames is stubbed to the file we just attached.
      allow_any_instance_of(BoardImage).to receive(:find_audio_for_voice).and_return(attachment)

      post "/api/board_images/#{board_image.id}/reset_audio", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response_audio_file(attachment)["current"]).to be(true)
      board_image.reload
      expect(board_image.using_custom_audio?).to be(false)
      expect(board_image.voice).to eq("polly:kevin")
    end

    it "never resolves back to the recording it is resetting away from" do
      custom_url = board_image.audio_url

      post "/api/board_images/#{board_image.id}/reset_audio", headers: auth_headers(user)

      expect(board_image.reload.using_custom_audio?).to be(false)
      # No voice file exists yet, so the tile keeps its URL and the job fills
      # it in — what it must not do is silently re-adopt the custom clip as
      # though it were the board voice.
      expect(board_image.audio_url).to eq(custom_url)
      expect(board_image.voice).to eq("polly:kevin")
    end

    it "queues audio generation when no file exists for the board voice" do
      expect(SaveAudioJob).to receive(:perform_async).with(board_image.image_id, "polly:kevin", board_image.id)

      post "/api/board_images/#{board_image.id}/reset_audio", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
    end

    it "leaves the tile with an audio_url rather than silencing it" do
      allow(SaveAudioJob).to receive(:perform_async)

      post "/api/board_images/#{board_image.id}/reset_audio", headers: auth_headers(user)

      expect(board_image.reload.audio_url).to be_present
    end
  end
end
