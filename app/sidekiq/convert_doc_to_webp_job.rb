class ConvertDocToWebpJob
  include Sidekiq::Job

  sidekiq_options retry: true, queue: :default

  def perform(doc_id)
    doc = Doc.find_by(id: doc_id)
    return unless doc&.image&.attached?

    blob = doc.image.blob
    return unless blob.content_type == "image/png"
    return if (doc.data || {})["converted_to_webp"] == true

    original_blob = blob
    original_filename_base = original_blob.filename.base

    downloaded = doc.image.download

    input_file = Tempfile.new(["doc_#{doc.id}_input", ".png"], binmode: true)
    output_file = Tempfile.new(["doc_#{doc.id}_output", ".webp"], binmode: true)

    begin
      input_file.write(downloaded)
      input_file.flush
      input_file.rewind

      processed = ImageProcessing::Vips
        .source(input_file.path)
        .convert("webp")
        .call(destination: output_file.path)

      output_file.rewind

      doc.image.attach(
        io: File.open(output_file.path, "rb"),
        filename: "#{original_filename_base}.webp",
        content_type: "image/webp",
      )

      original_blob.purge_later

      doc.update!(
        data: (doc.data || {}).merge(
          converted_to_webp: true,
          original_content_type: original_blob.content_type,
          converted_from_blob_id: original_blob.id,
        ),
      )
    ensure
      input_file.close!
      output_file.close!
    end
  end
end
