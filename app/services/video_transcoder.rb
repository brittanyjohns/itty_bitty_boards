# Thin wrapper around the `ffmpeg` / `ffprobe` binaries.
#
# Two callers with different jobs: ProcessTileVideoJob normalizes a parent's
# uploaded tile clip (#transcode), and Boards::Printables::RenderListingVideo
# builds a marketplace listing video out of rendered still frames
# (#encode_image_sequence).
#
# Shells out rather than pulling in a gem — the surface we need is small and
# both binaries are already listed as system dependencies in the README.
#
# Every method fails soft: a missing binary, a malformed file, or a non-zero
# exit returns nil/false rather than raising, so a bad upload can never take
# down the job that calls it. Callers must check `available?` before assuming
# a transcode is possible — see ProcessTileVideoJob.
class VideoTranscoder
  # Container/codec the web player is guaranteed to handle.
  OUTPUT_CONTENT_TYPE = "video/mp4".freeze

  # Cap the transcode cost of a pathological upload. A 30s tile clip should
  # take a couple of seconds; anything past this is wedged. Overridable per
  # call because the two callers have quite different profiles.
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

    # Encode still images, each held for its own duration, into an H.264 mp4.
    #
    # `entries` is [[path, seconds], ...] in playback order. Every image must
    # share the same pixel dimensions — the concat filter refuses a size change
    # mid-stream, and the one caller renders every frame at a fixed square.
    #
    # Built as one looped input per frame plus a concat FILTER, NOT the concat
    # demuxer with a `duration`-per-`file` manifest. The demuxer looks like the
    # obvious tool and its timing does not survive contact with still images:
    # measured against ffmpeg 8.1, durations of 1/2/4s produced a 5s clip, and
    # the widely-repeated "repeat the last file" workaround produced 11s. The
    # construction below reproduces the requested total to within a frame,
    # which was verified across 3, 4 and 10 frames before it was written.
    #
    # `-loop 1 -t N` gives each frame an exact length; the filter joins them.
    # Frame counts here are single digits, so the input list stays small.
    #
    # Deliberately NOT a call into #transcode: that takes a single `-i`, and it
    # hardcodes an AAC audio stream a slideshow has no source for.
    #
    #   -an       no audio. There is none, and a marketplace strips a listing
    #             video's audio track anyway.
    #   -crf 20   not #transcode's 26. These frames are flat colour blocks and
    #             text; 26 puts visible mosquito noise on every tile border. A
    #             ~12s 1080-square clip is a few MB either way.
    #   -t        a hard ceiling, so a miscomputed plan yields a short clip
    #             rather than one a marketplace rejects on length.
    def encode_still_sequence(entries, output_path, max_seconds:, timeout: TIMEOUT_SECONDS)
      return false if entries.blank?

      inputs = entries.flat_map { |path, seconds| ["-loop", "1", "-t", format("%.3f", seconds), "-i", path.to_s] }
      streams = entries.each_index.map { |i| "[#{i}:v]" }.join

      _stdout, stderr, status = run(
        "ffmpeg", "-y",
        *inputs,
        "-filter_complex",
        "#{streams}concat=n=#{entries.size}:v=1:a=0[joined];[joined]fps=30,format=yuv420p[out]",
        "-map", "[out]",
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-crf", "20",
        "-an",
        "-movflags", "+faststart",
        "-t", max_seconds.to_s,
        output_path.to_s,
        timeout: timeout
      )
      return true if status&.success? && File.size?(output_path.to_s)

      Rails.logger.warn("[VideoTranscoder] encode failed: #{stderr.to_s.lines.last(3).join.strip}")
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
    def run(*args, timeout: TIMEOUT_SECONDS)
      Timeout.timeout(timeout) { Open3.capture3(*args) }
    rescue Timeout::Error
      Rails.logger.warn("[VideoTranscoder] timed out after #{timeout}s: #{args.first}")
      [nil, nil, nil]
    rescue Errno::ENOENT => e
      Rails.logger.warn("[VideoTranscoder] binary missing: #{e.message}")
      [nil, nil, nil]
    end
  end
end
