namespace :images do
  desc "Convert PNG images to WebP"
  task convert_png_to_webp: :environment do
    board_id = ENV["BOARD_ID"]
    if board_id.present?
      puts "Filtering to boards with id=#{board_id}"
      board = Board.find_by(id: board_id)
      unless board
        puts "Board with id=#{board_id} not found"
        exit(1)
      end
      board.board_images.includes(:image).find_each do |board_image|
        image = board_image.image
        puts "Processing image #{image.id} for board #{board.id} = #{image.label}"
        current_docs = Doc.where(documentable: image).with_attached_image
          .where("docs.data ->> 'converted_to_webp' IS DISTINCT FROM 'true'")
          .joins(:image_attachment, :image_blob)
          .where(active_storage_blobs: { content_type: "image/png" })
        current_docs.find_each do |doc|
          ConvertDocToWebpJob.perform_async(doc.id)
        end
      end
      puts "Enqueued conversion jobs for PNG images on board #{board_id}"
    else
      docs = Doc.joins("INNER JOIN images ON images.id = docs.documentable_id")
        .where(documentable_type: "Image")
        .with_attached_image
        .where("docs.data ->> 'converted_to_webp' IS DISTINCT FROM 'true'")
        .joins(:image_attachment, :image_blob)
        .where(active_storage_blobs: { content_type: "image/png" })
      puts "Found #{docs.count} PNG images"

      docs.each do |doc|
        ConvertDocToWebpJob.perform_async(doc.id)
      end
    end
  end
end
