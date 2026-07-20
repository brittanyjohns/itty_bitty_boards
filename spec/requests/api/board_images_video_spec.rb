require "rails_helper"

# Tile video actions: video config lives in board_images.data["video"] and is
# only writable through the dedicated validated endpoints — never through the
# generic update path (which strips the key).
RSpec.describe "API::BoardImages video", type: :request do
  let!(:user)        { create(:user) }
  let!(:board)       { create(:board, user: user) }
  let!(:board_image) { create(:board_image, board: board) }

  let(:valid_youtube_url) { "https://www.youtube.com/watch?v=dQw4w9WgXcQ" }

  def upload_file(content_type: "video/mp4")
    Rack::Test::UploadedFile.new(
      Rails.root.join("spec/fixtures/files/tiny_video.mp4"),
      content_type,
    )
  end

  describe "POST /api/board_images/:id/attach_youtube_video" do
    it "persists only the parsed video id" do
      post "/api/board_images/#{board_image.id}/attach_youtube_video",
           params: { url: valid_youtube_url },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      video = board_image.reload.data["video"]
      expect(video).to eq({ "source" => "youtube", "youtube_id" => "dQw4w9WgXcQ" })
      expect(JSON.parse(response.body).dig("data", "video", "youtube_id")).to eq("dQw4w9WgXcQ")
    end

    it "rejects a non-YouTube URL with 422 and writes nothing" do
      post "/api/board_images/#{board_image.id}/attach_youtube_video",
           params: { url: "https://evil.example/watch?v=dQw4w9WgXcQ" },
           headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("invalid_youtube_url")
      expect(board_image.reload.data&.dig("video")).to be_nil
    end

    it "preserves unrelated data keys" do
      board_image.update!(data: { "hide_label" => true })
      post "/api/board_images/#{board_image.id}/attach_youtube_video",
           params: { url: valid_youtube_url },
           headers: auth_headers(user)

      expect(board_image.reload.data["hide_label"]).to eq(true)
      expect(board_image.data["video"]["youtube_id"]).to eq("dQw4w9WgXcQ")
    end

    it "persists an optional trim range alongside the video id" do
      post "/api/board_images/#{board_image.id}/attach_youtube_video",
           params: { url: valid_youtube_url, start_seconds: 45, end_seconds: 72 },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(board_image.reload.data["video"]).to eq({
        "source" => "youtube",
        "youtube_id" => "dQw4w9WgXcQ",
        "start_seconds" => 45,
        "end_seconds" => 72,
      })
    end

    it "stores no range keys when neither bound is supplied" do
      post "/api/board_images/#{board_image.id}/attach_youtube_video",
           params: { url: valid_youtube_url },
           headers: auth_headers(user)

      expect(board_image.reload.data["video"].keys)
        .to contain_exactly("source", "youtube_id")
    end

    it "accepts a start with no end" do
      post "/api/board_images/#{board_image.id}/attach_youtube_video",
           params: { url: valid_youtube_url, start_seconds: 45 },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      video = board_image.reload.data["video"]
      expect(video["start_seconds"]).to eq(45)
      expect(video).not_to have_key("end_seconds")
    end

    it "rejects an unusable range with 422 and writes nothing" do
      post "/api/board_images/#{board_image.id}/attach_youtube_video",
           params: { url: valid_youtube_url, start_seconds: 72, end_seconds: 45 },
           headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("invalid_video_range")
      expect(board_image.reload.data&.dig("video")).to be_nil
    end

    it "replaces a previous range when re-attached without one" do
      post "/api/board_images/#{board_image.id}/attach_youtube_video",
           params: { url: valid_youtube_url, start_seconds: 45, end_seconds: 72 },
           headers: auth_headers(user)
      post "/api/board_images/#{board_image.id}/attach_youtube_video",
           params: { url: valid_youtube_url },
           headers: auth_headers(user)

      expect(board_image.reload.data["video"].keys)
        .to contain_exactly("source", "youtube_id")
    end
  end

  describe "POST /api/board_images/:id/upload_video" do
    it "attaches an mp4 and stores the upload config" do
      post "/api/board_images/#{board_image.id}/upload_video",
           params: { video_file: upload_file },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      board_image.reload
      expect(board_image.video_clip).to be_attached
      video = board_image.data["video"]
      expect(video["source"]).to eq("upload")
      expect(video["content_type"]).to eq("video/mp4")
      expect(video["url"]).to be_present
    end

    it "enqueues the post-process job to enforce duration and transcode" do
      post "/api/board_images/#{board_image.id}/upload_video",
           params: { video_file: upload_file },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(ProcessTileVideoJob.jobs.last["args"]).to eq([board_image.id])
    end

    it "rejects a content type we can never play with 422 and attaches nothing" do
      post "/api/board_images/#{board_image.id}/upload_video",
           params: { video_file: upload_file(content_type: "video/x-msvideo") },
           headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("invalid_video_type")
      expect(board_image.reload.video_clip).not_to be_attached
    end

    # The .mov accept path is gated on the binaries: we only take a format we
    # can guarantee we're able to convert into something browsers will play.
    context "quicktime/.mov uploads" do
      it "accepts them when ffmpeg is available" do
        allow(VideoTranscoder).to receive(:available?).and_return(true)

        post "/api/board_images/#{board_image.id}/upload_video",
             params: { video_file: upload_file(content_type: "video/quicktime") },
             headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        board_image.reload
        expect(board_image.video_clip).to be_attached
        expect(board_image.video_clip.blob.filename.to_s).to end_with(".mov")
        # Not yet web-safe — the job flips this once it has converted.
        expect(board_image.video_processed?).to be(false)
      end

      it "rejects them when ffmpeg is unavailable" do
        allow(VideoTranscoder).to receive(:available?).and_return(false)

        post "/api/board_images/#{board_image.id}/upload_video",
             params: { video_file: upload_file(content_type: "video/quicktime") },
             headers: auth_headers(user)

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to eq("invalid_video_type")
        expect(board_image.reload.video_clip).not_to be_attached
      end
    end

    describe "size cap" do
      it "allows the larger source cap when ffmpeg can shrink the file" do
        allow(VideoTranscoder).to receive(:available?).and_return(true)

        expect(BoardImage.max_video_upload_bytes).to eq(BoardImage::MAX_VIDEO_SOURCE_BYTES)
      end

      it "falls back to the stored-file cap without ffmpeg" do
        allow(VideoTranscoder).to receive(:available?).and_return(false)

        expect(BoardImage.max_video_upload_bytes).to eq(BoardImage::MAX_VIDEO_BYTES)
      end
    end

    it "rejects an oversized file with 422" do
      allow(VideoTranscoder).to receive(:available?).and_return(false)
      stub_const("BoardImage::MAX_VIDEO_BYTES", 10)
      post "/api/board_images/#{board_image.id}/upload_video",
           params: { video_file: upload_file },
           headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("video_too_large")
      expect(board_image.reload.video_clip).not_to be_attached
    end

    it "rejects a missing file with 422" do
      post "/api/board_images/#{board_image.id}/upload_video",
           headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("video_required")
    end

    it "replaces a previous youtube config" do
      board_image.set_youtube_video!("dQw4w9WgXcQ")
      post "/api/board_images/#{board_image.id}/upload_video",
           params: { video_file: upload_file },
           headers: auth_headers(user)

      video = board_image.reload.data["video"]
      expect(video["source"]).to eq("upload")
      expect(video["youtube_id"]).to be_nil
    end
  end

  describe "POST /api/board_images/:id/clear_video" do
    it "removes the video config and purges the clip, keeping other data keys" do
      board_image.update!(data: { "hide_label" => true })
      post "/api/board_images/#{board_image.id}/upload_video",
           params: { video_file: upload_file },
           headers: auth_headers(user)
      expect(board_image.reload.video_clip).to be_attached

      post "/api/board_images/#{board_image.id}/clear_video",
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      board_image.reload
      expect(board_image.data["video"]).to be_nil
      expect(board_image.data["hide_label"]).to eq(true)
    end
  end

  describe "generic update cannot touch video config" do
    it "strips an injected video key instead of persisting it" do
      patch "/api/board_images/#{board_image.id}",
            params: { board_image: { data: { video: { source: "upload", url: "https://evil.example/x.mp4" } } } },
            headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(board_image.reload.data&.dig("video")).to be_nil
    end

    it "does not clobber an existing video config on unrelated updates" do
      board_image.set_youtube_video!("dQw4w9WgXcQ")
      patch "/api/board_images/#{board_image.id}",
            params: { board_image: { bg_color: "#ffffff", data: { hide_label: true, video: nil } } },
            headers: auth_headers(user),
            as: :json

      expect(response).to have_http_status(:ok)
      board_image.reload
      expect(board_image.data["video"]["youtube_id"]).to eq("dQw4w9WgXcQ")
      expect(board_image.data["hide_label"]).to eq(true)
    end
  end

  describe "board payload passthrough" do
    it "includes the video config in the bulk board serialization via data" do
      board_image.set_youtube_video!("dQw4w9WgXcQ")
      payload = board.api_view_with_predictive_images(user)
      tile = payload[:images].find { |img| img[:id] == board_image.id }
      expect(tile[:data]["video"]["youtube_id"]).to eq("dQw4w9WgXcQ")
    end
  end

  describe "OBF export" do
    it "adds ext_saw_video keys only when a video is configured" do
      expect(board_image.to_obf_button_format).not_to have_key(:ext_saw_video_source)

      board_image.set_youtube_video!("dQw4w9WgXcQ")
      btn = board_image.reload.to_obf_button_format
      expect(btn[:ext_saw_video_source]).to eq("youtube")
      expect(btn[:ext_saw_video_youtube_id]).to eq("dQw4w9WgXcQ")
    end
  end
end
