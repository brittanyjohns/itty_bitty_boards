namespace :images do
  desc "Convert PNG images to WebP"
  task convert_png_to_webp: :environment do
    scope = Doc.joins(:image_attachment, :image_blob)
      .where(active_storage_blobs: { content_type: "image/png" })

    puts "Found #{scope.count} PNG images"

    scope.find_each do |doc|
      ConvertDocToWebpJob.perform_async(doc.id)
    end
  end
end
