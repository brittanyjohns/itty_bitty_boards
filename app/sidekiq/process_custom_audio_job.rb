# Normalizes a recorded/uploaded tile clip to mp3 and enforces the duration
# cap server-side.
#
# upload_audio accepts the file and responds immediately with the raw URL so
# the editor isn't blocked on ffmpeg; this job then swaps in the converted
# clip and rebroadcasts the board, which is how an open editor and any live
# communicator session pick up the new URL.
#
# Fails soft: if ffmpeg is missing or the transcode errors, the original
# upload stays attached and playable. That's only ever an already-web-safe
# format — upload_audio refuses webm outright when the binaries aren't
# available, so we can't be left holding a clip an iPad can't play.
class ProcessCustomAudioJob
  include Sidekiq::Job

  sidekiq_options retry: 3, queue: :default

  def perform(board_image_id, attachment_id)
    board_image = BoardImage.find_by(id: board_image_id)
    return unless board_image

    attachment = board_image.audio_files.find_by(id: attachment_id)
    return unless attachment&.blob

    blob = attachment.blob
    return if BoardImage::ALLOWED_AUDIO_CONTENT_TYPES.include?(blob.content_type)

    unless AudioTranscoder.available?
      Rails.logger.warn(
        "[ProcessCustomAudioJob] ffmpeg unavailable; leaving board_image #{board_image_id} audio unconverted",
      )
      return
    end

    # Whether the tile is still on the clip we're about to convert. Decided
    # from the records, not by comparing URLs: the Disk service signs its URLs,
    # so re-generating one for the same blob yields a different string every
    # time and the tile would never be repointed.
    tile_on_this_clip = board_image.using_custom_audio? &&
      board_image.audio_files_attachments.order(:id).last&.id == attachment.id

    input = Tempfile.new(["tile_audio_#{board_image_id}_in", extension_for(blob.filename.to_s)], binmode: true)
    output = Tempfile.new(["tile_audio_#{board_image_id}_out", ".#{AudioTranscoder::OUTPUT_EXTENSION}"], binmode: true)

    begin
      input.write(attachment.download)
      input.flush
      input.rewind

      unless AudioTranscoder.transcode(
        input.path, output.path, max_seconds: BoardImage::MAX_AUDIO_DURATION_SECONDS
      )
        Rails.logger.warn("[ProcessCustomAudioJob] transcode failed for board_image #{board_image_id}; leaving as-is")
        return
      end

      filename = "#{File.basename(blob.filename.to_s, ".*")}.#{AudioTranscoder::OUTPUT_EXTENSION}"
      board_image.audio_files.attach(
        io: File.open(output.path, "rb"),
        filename: filename,
        content_type: AudioTranscoder::OUTPUT_CONTENT_TYPE,
      )
      board_image.reload

      converted = board_image.audio_files.find { |af| af.blob.filename.to_s == filename }
      return unless converted

      # Only repoint a tile still playing the file we just converted — the user
      # may have recorded again, or switched to a voice, while this ran.
      if tile_on_this_clip
        board_image.set_custom_audio!(board_image.default_audio_url(converted))
      end
      # Purge after the replacement is attached and the new URL is persisted,
      # so a failure mid-way never leaves the tile pointing at a dead blob.
      attachment.purge_later
      board_image.board&.broadcast_board_update!
    ensure
      input.close!
      output.close!
    end
  end

  private

  def extension_for(filename)
    ext = File.extname(filename.to_s)
    ext.presence || ".webm"
  end
end
