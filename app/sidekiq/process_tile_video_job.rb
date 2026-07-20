# Post-processes an uploaded tile video: enforces the 30s cap server-side and
# transcodes to a web-safe H.264 mp4.
#
# upload_video accepts the file and responds immediately with the raw URL, so
# the editor isn't blocked on ffmpeg. This job then swaps in the processed
# clip and broadcasts the board, which is how the open editor picks up the new
# URL.
#
# Fails soft by design: if ffmpeg is missing or the transcode errors, the
# original upload is left attached and playable rather than destroyed. That
# only happens for mp4/webm — upload_video refuses .mov outright when the
# binaries aren't available, so we can never be left holding an unplayable
# clip we have no way to convert.
class ProcessTileVideoJob
  include Sidekiq::Job

  sidekiq_options retry: 3, queue: :default

  # Containers that need no re-encode when the codec and duration are already
  # fine. webm is left alone — it plays everywhere mp4 doesn't.
  PASSTHROUGH_CONTENT_TYPES = %w[video/mp4 video/webm].freeze
  WEB_SAFE_CODECS = %w[h264].freeze

  def perform(board_image_id)
    board_image = BoardImage.find_by(id: board_image_id)
    return unless board_image&.video_clip&.attached?

    config = board_image.video_config
    return unless config && config["source"] == "upload"
    return if board_image.video_processed?

    unless VideoTranscoder.available?
      Rails.logger.warn(
        "[ProcessTileVideoJob] ffmpeg/ffprobe unavailable; leaving board_image #{board_image_id} unprocessed",
      )
      return
    end

    blob = board_image.video_clip.blob
    input = Tempfile.new(["tile_video_#{board_image_id}_in", extension_for(blob.content_type)], binmode: true)
    output = Tempfile.new(["tile_video_#{board_image_id}_out", ".mp4"], binmode: true)

    begin
      input.write(board_image.video_clip.download)
      input.flush
      input.rewind

      duration = VideoTranscoder.duration(input.path)
      if duration.nil?
        Rails.logger.warn("[ProcessTileVideoJob] could not probe board_image #{board_image_id}; leaving as-is")
        return
      end

      if passthrough?(blob.content_type, duration, input.path)
        # Already web-safe and within the cap — just record what we measured
        # so we don't probe it again.
        board_image.set_uploaded_video!(
          config["url"], blob.content_type, duration: duration, processed: true
        )
        board_image.board.broadcast_board_update!
        return
      end

      unless VideoTranscoder.transcode(
        input.path, output.path, max_seconds: BoardImage::MAX_VIDEO_DURATION_SECONDS
      )
        Rails.logger.warn("[ProcessTileVideoJob] transcode failed for board_image #{board_image_id}; leaving as-is")
        return
      end

      original_blob = blob
      filename = "board-image-#{board_image.id}-video-#{Time.now.strftime("%m%d%y%H%M%S")}.mp4"

      board_image.video_clip.attach(
        io: File.open(output.path, "rb"),
        filename: filename,
        content_type: VideoTranscoder::OUTPUT_CONTENT_TYPE,
      )
      board_image.reload

      board_image.set_uploaded_video!(
        board_image.video_clip_url,
        VideoTranscoder::OUTPUT_CONTENT_TYPE,
        duration: [duration, BoardImage::MAX_VIDEO_DURATION_SECONDS].min,
        processed: true,
      )
      # Purge only after the replacement is attached and the new URL is
      # persisted, so a failure mid-way never leaves the tile pointing at a
      # blob that no longer exists.
      original_blob.purge_later
      board_image.board.broadcast_board_update!
    ensure
      input.close!
      output.close!
    end
  end

  private

  # Skip the re-encode when the clip is already in a container the player
  # handles, uses a web-safe codec, and is within the duration cap.
  def passthrough?(content_type, duration, path)
    return false unless PASSTHROUGH_CONTENT_TYPES.include?(content_type)
    return false if duration > BoardImage::MAX_VIDEO_DURATION_SECONDS
    return true if content_type == "video/webm"

    WEB_SAFE_CODECS.include?(VideoTranscoder.video_codec(path))
  end

  def extension_for(content_type)
    case content_type
    when "video/webm" then ".webm"
    when "video/quicktime" then ".mov"
    else ".mp4"
    end
  end
end
