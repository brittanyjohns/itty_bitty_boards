namespace :translate do
  desc "Translate all image labels on a board into LANG (e.g. LANG=es BOARD_ID=42)"
  task board: :environment do
    board_id = ENV["BOARD_ID"]
    language = ENV["LANG"]

    if board_id.blank? || language.blank?
      puts "Usage: rake translate:board BOARD_ID=<id> LANG=<iso-639-1>"
      exit(1)
    end

    board = Board.find_by(id: board_id)
    unless board
      puts "Board with id=#{board_id} not found"
      exit(1)
    end

    unless Image.languages.include?(language)
      puts "Language #{language.inspect} is not in Image.languages (#{Image.languages.join(", ")})"
      exit(1)
    end

    puts "Queueing translations for board #{board.id} (#{board.name}) into #{language}"
    TranslateBoardImagesJob.perform_async(board.id, language)
  end

  desc "Translate the public image library into LANG (e.g. LANG=es)"
  task public_images: :environment do
    language = ENV["LANG"]
    if language.blank?
      puts "Usage: rake translate:public_images LANG=<iso-639-1>"
      exit(1)
    end

    unless Image.languages.include?(language)
      puts "Language #{language.inspect} is not in Image.languages (#{Image.languages.join(", ")})"
      exit(1)
    end

    public_board_ids = Board.public_boards.pluck(:id)
    image_ids = BoardImage.where(board_id: public_board_ids).pluck(:image_id)
    # We only want to translate images that are actually used in public boards, so we join with the images table and use distinct to avoid duplicates.
    queued = 0
    scope = Image.where(id: image_ids).distinct
    total = scope.count
    scope.find_each do |image|
      existing = (image.language_settings || {})[language]
      next if existing.is_a?(Hash) && (existing["label"] || existing[:label]).to_s.strip.present?

      TranslateImageJob.perform_async(image.id, language)
      queued += 1
    end

    puts "Queued #{queued}/#{total} images for translation into #{language}"
  end
end
