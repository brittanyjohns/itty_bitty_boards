# Thin wrapper around `ffmpeg` / `ffprobe` for user-recorded tile audio.
#
# Same shape and the same fail-soft contract as VideoTranscoder: a missing
# binary, a malformed file, or a non-zero exit returns nil/false rather than
# raising, so a bad recording can never take down the job that calls it.
#
# The reason this exists at all: MediaRecorder hands us audio/webm on Chrome,
# and Safari on iPad won't play it — which is the device most communicators
# actually use. Recordings are normalized to mp3 before they can be tapped.
class AudioTranscoder
  OUTPUT_CONTENT_TYPE = "audio/mpeg".freeze
  OUTPUT_EXTENSION = "mp3".freeze

  # A 60s clip transcodes in well under a second; past this it's wedged.
  TIMEOUT_SECONDS = 60

  class << self
    def available?
      return @available unless @available.nil?
      @available = binary?("ffmpeg") && binary?("ffprobe")
    end

    # Test seam — `available?` memoizes.
    def reset_availability!
      @available = nil
    end

    # Duration in seconds, or nil if ffprobe can't read the file.
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

    # Transcode to mono 64kbps mp3, trimmed to `max_seconds`. Mono because
    # these are single-voice recordings played through a tablet speaker —
    # stereo doubles the bytes a communicator has to cache for offline use and
    # buys nothing.
    def transcode(input_path, output_path, max_seconds:)
      _stdout, stderr, status = run(
        "ffmpeg", "-y",
        "-i", input_path.to_s,
        "-t", max_seconds.to_s,
        "-vn",
        "-ac", "1",
        "-ar", "44100",
        "-c:a", "libmp3lame",
        "-b:a", "64k",
        output_path.to_s
      )
      return true if status&.success? && File.size?(output_path.to_s)

      Rails.logger.warn("[AudioTranscoder] transcode failed: #{stderr.to_s.lines.last(3).join.strip}")
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
      Rails.logger.warn("[AudioTranscoder] timed out after #{TIMEOUT_SECONDS}s: #{args.first}")
      [nil, nil, nil]
    rescue Errno::ENOENT => e
      Rails.logger.warn("[AudioTranscoder] binary missing: #{e.message}")
      [nil, nil, nil]
    end
  end
end
