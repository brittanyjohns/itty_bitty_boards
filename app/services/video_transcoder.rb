# Thin wrapper around the `ffmpeg` / `ffprobe` binaries for tile video clips.
#
# Shells out rather than pulling in a gem — the surface we need is two calls
# (probe duration, transcode to web-safe mp4) and both binaries are already
# listed as system dependencies in the README.
#
# Every method fails soft: a missing binary, a malformed file, or a non-zero
# exit returns nil/false rather than raising, so a bad upload can never take
# down the job that calls it. Callers must check `available?` before assuming
# a transcode is possible — see ProcessTileVideoJob.
class VideoTranscoder
  # Container/codec the web player is guaranteed to handle.
  OUTPUT_CONTENT_TYPE = "video/mp4".freeze

  # Cap the transcode cost of a pathological upload. A 30s tile clip should
  # take a couple of seconds; anything past this is wedged.
  TIMEOUT_SECONDS = 120

  class << self
    # True only when both binaries are on PATH. Memoized per process — the
    # answer can't change without a restart, and this is hit on every upload.
    def available?
      return @available unless @available.nil?
      @available = binary?("ffmpeg") && binary?("ffprobe")
    end

    # Test seam: `available?` memoizes, so specs that stub the binaries need a
    # way to clear it.
    def reset_availability!
      @available = nil
    end

    # Duration of the file in seconds, or nil if ffprobe can't read it.
    def duration(path)
      stdout, _stderr, status = run(
        "ffprobe", "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        path.to_s
      )
      return nil unless status&.success?

      value = stdout.to_s.strip.to_f
      value.positive? ? value : nil
    end

    # Name of the video codec ("h264", "hevc", ...), or nil if unreadable.
    # Used to skip re-encoding clips that are already web-safe.
    def video_codec(path)
      stdout, _stderr, status = run(
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=codec_name",
        "-of", "default=noprint_wrappers=1:nokey=1",
        path.to_s
      )
      return nil unless status&.success?

      stdout.to_s.strip.presence
    end

    # Transcode to H.264/AAC mp4, trimming to `max_seconds`.
    #
    # `-movflags +faststart` moves the moov atom to the front so the clip can
    # start playing before it has fully downloaded — without it a tile video
    # stalls until the whole file lands. Returns true on success.
    def transcode(input_path, output_path, max_seconds:)
      _stdout, stderr, status = run(
        "ffmpeg", "-y",
        "-i", input_path.to_s,
        "-t", max_seconds.to_s,
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-crf", "26",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac",
        "-b:a", "128k",
        "-movflags", "+faststart",
        output_path.to_s
      )
      return true if status&.success? && File.size?(output_path.to_s)

      Rails.logger.warn("[VideoTranscoder] transcode failed: #{stderr.to_s.lines.last(3).join.strip}")
      false
    end

    private

    def binary?(name)
      _stdout, _stderr, status = Open3.capture3("which", name)
      status.success?
    rescue Errno::ENOENT, StandardError
      false
    end

    # Never raises — callers branch on the status instead.
    def run(*args)
      Timeout.timeout(TIMEOUT_SECONDS) { Open3.capture3(*args) }
    rescue Timeout::Error
      Rails.logger.warn("[VideoTranscoder] timed out after #{TIMEOUT_SECONDS}s: #{args.first}")
      [nil, nil, nil]
    rescue Errno::ENOENT => e
      Rails.logger.warn("[VideoTranscoder] binary missing: #{e.message}")
      [nil, nil, nil]
    end
  end
end
