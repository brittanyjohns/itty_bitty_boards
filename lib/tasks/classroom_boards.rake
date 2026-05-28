namespace :classroom_boards do
  TARGET_GROUP_NAME = "School".freeze

  CLASSROOM_BOARDS = [
    {
      name: "Morning Routine",
      description: "Get the school day started — wake-up through walking into class.",
      tags: %w[school daily-routine visual-schedule beginner],
      labels: [
        "wake up", "stretch", "brush teeth", "wash face", "get dressed",
        "eat breakfast", "pack bag", "put on shoes", "leave house",
        "ride bus", "walk to school", "good morning",
      ],
    },
    {
      name: "Visual Schedule",
      description: "First / then / next — sequencing the school day for students who do better with a clear order.",
      tags: %w[school visual-schedule first-then daily-routine],
      labels: [
        "first", "then", "next", "last",
        "morning meeting", "work time", "snack", "recess",
        "lunch", "specials", "reading", "math",
        "centers", "clean up", "dismissal", "go home",
      ],
    },
    {
      name: "Emotions",
      description: "Name what you feel — a starter emotions board for the classroom.",
      tags: %w[school feelings beginner core-words],
      labels: [
        "happy", "sad", "mad", "tired", "frustrated", "proud",
        "calm", "excited", "scared", "surprised", "okay", "not okay",
      ],
    },
    {
      name: "Center Choices",
      description: "Pick a center — for choice time, center rotations, and free play.",
      tags: %w[school choice-board play],
      labels: [
        "reading corner", "art", "blocks", "sensory bin",
        "writing", "computer", "puzzles", "dramatic play",
        "math games", "library", "music", "outside",
      ],
    },
    {
      name: "Lunch and Snack",
      description: "Lunchroom and snack-time vocabulary — for cafeteria, classroom snack, and home lunches.",
      tags: %w[school choice-board home],
      labels: [
        "milk", "water", "juice", "sandwich",
        "fruit", "crackers", "apple", "banana",
        "yogurt", "more please", "all done", "help",
      ],
    },
    {
      name: "Transitions",
      description: "Move between activities — the in-between moments that are often the hardest part of the day.",
      tags: %w[school daily-routine visual-schedule],
      labels: [
        "line up", "hallway", "quiet voice", "walking feet",
        "restroom", "water fountain", "back to seat", "clean up",
        "calm down", "deep breath", "wait", "ready",
      ],
    },
  ].freeze

  desc "Audit teacher-relevant public boards (read-only)"
  task audit: :environment do
    ActiveRecord::Base.logger.level = Logger::WARN
    admin_id = User::DEFAULT_ADMIN_ID
    teacher_tags = %w[school home visual-schedule visual\ schedule daily-routine daily\ routine choice-board choice\ board first-then feelings safety]

    puts ""
    puts "=" * 60
    puts "Classroom Boards Audit"
    puts "=" * 60
    puts "Admin user id: #{admin_id}"
    puts "Total public boards: #{Board.public_boards.count}"

    puts ""
    puts "Public boards with teacher-relevant tags:"
    matches = Board.public_boards.where("tags && ARRAY[?]::varchar[]", teacher_tags)
    if matches.empty?
      puts "  (none)"
    else
      matches.pluck(:name, :tags).each { |name, tags| puts "  - #{name.inspect} #{tags.inspect}" }
    end

    puts ""
    puts "Target board name → status:"
    CLASSROOM_BOARDS.each do |b|
      existing = Board.where(name: b[:name], user_id: admin_id)
      if existing.exists?
        flags = existing.pluck(:predefined, :published).map { |p, pub| "predefined=#{p} published=#{pub}" }.join(", ")
        puts "  ✓ #{b[:name]} exists (#{flags})"
      else
        puts "  ✗ #{b[:name]} missing"
      end
    end

    puts ""
    puts "Featured board groups: #{BoardGroup.featured.pluck(:name).inspect}"
    target_group = BoardGroup.find_by(name: TARGET_GROUP_NAME)
    if target_group
      puts "Target group #{TARGET_GROUP_NAME.inspect}: id=#{target_group.id} predefined=#{target_group.predefined} featured=#{target_group.featured} boards=#{target_group.boards.count}"
      puts "Existing boards in #{TARGET_GROUP_NAME.inspect}:"
      target_group.boards.each do |b|
        puts "  - #{b.name} (id=#{b.id}, published=#{b.published}, predefined=#{b.predefined}, tags=#{b.tags.inspect}, images=#{b.images.count})"
      end
    else
      puts "Target group #{TARGET_GROUP_NAME.inspect}: does not exist (seed will create it)"
    end
    puts ""
  end

  desc "Seed 6 teacher boards into the target Board Group (idempotent, no AI calls)"
  task seed: :environment do
    ActiveRecord::Base.logger.level = Logger::WARN
    admin = User.find(User::DEFAULT_ADMIN_ID)
    parent_resource = PredefinedResource.find_or_create_by!(name: "Default", resource_type: "Board")

    puts ""
    puts "Seeding teacher boards into #{TARGET_GROUP_NAME.inspect}..."
    puts "  Admin user: #{admin.email} (id=#{admin.id})"

    seeded_boards = CLASSROOM_BOARDS.map do |spec|
      board = Board.find_or_initialize_by(name: spec[:name], user_id: admin.id, predefined: true)
      is_new = board.new_record?

      board.assign_attributes(
        description: spec[:description],
        parent: parent_resource,
        predefined: true,
        published: true,
        tags: spec[:tags],
      )
      board.generate_unique_slug if board.slug.blank?
      board.save!

      spec[:labels].each do |label|
        next if board.images.where("LOWER(images.label) = ?", label.downcase).exists?
        image = Image.default_public.find_or_create_by!(label: label.downcase) do |img|
          img.image_prompt = "Create a clean, simple image representing '#{label}'."
        end
        board.add_image(image.id)
      end

      action = is_new ? "created" : "updated"
      puts "  #{action.rjust(7)}: #{spec[:name]} (id=#{board.id}, #{spec[:labels].size} cells, tags=#{spec[:tags].inspect})"
      board
    end

    group = BoardGroup.find_or_initialize_by(name: TARGET_GROUP_NAME)
    group_is_new = group.new_record?
    if group_is_new
      group.assign_attributes(user_id: admin.id, predefined: true, featured: true)
      group.save!
    end

    seeded_boards.each do |board|
      group.board_group_boards.find_or_create_by!(board: board)
    end

    action = group_is_new ? "created" : "found existing"
    puts ""
    puts "  Target group: #{action} #{TARGET_GROUP_NAME.inspect} (id=#{group.id}, predefined=#{group.predefined}, featured=#{group.featured}, total boards now=#{group.boards.count})"
    puts ""
    puts "Done. Run 'bin/rails classroom_boards:audit' to verify."
    puts "Next: 'bin/rails classroom_boards:generate_images' to queue symbol/image generation."
    puts ""
  end

  desc "Queue OpenAI image generation for missing teacher-board artwork. DRY_RUN=1 to preview without queuing."
  task generate_images: :environment do
    ActiveRecord::Base.logger.level = Logger::WARN
    dry_run = %w[1 true yes].include?(ENV["DRY_RUN"].to_s.downcase)

    group = BoardGroup.find_by(name: TARGET_GROUP_NAME)
    unless group
      abort "#{TARGET_GROUP_NAME.inspect} group not found. Run 'bin/rails classroom_boards:seed' first."
    end

    seeded_names = CLASSROOM_BOARDS.map { |b| b[:name] }
    new_boards = group.boards.where(name: seeded_names).includes(:images)

    # One job per (image, board) so each BoardImage status is tracked correctly.
    # Skip anything that already has artwork to avoid burning credits.
    pending = []
    new_boards.each do |board|
      board.images.each do |image|
        next if image.docs.any?
        next if image.image_prompt.blank?
        pending << [image, board]
      end
    end

    if pending.empty?
      puts "All teacher-board images already have artwork. Nothing to queue."
      next
    end

    admin_id = User::DEFAULT_ADMIN_ID
    estimated_low = pending.size * 0.04
    estimated_high = pending.size * 0.08

    if dry_run
      puts ""
      puts "DRY RUN — no jobs queued, no API calls, no $$ spent."
      puts "=" * 60
      puts "Would queue GenerateImageJob for #{pending.size} (image, board) pair(s):"
      puts ""
      pending.group_by { |_, board| board.name }.each do |board_name, pairs|
        puts "  #{board_name} (#{pairs.size} image(s)):"
        pairs.each do |image, _|
          prompt = image.image_prompt.to_s
          prompt_preview = prompt.length > 60 ? "#{prompt[0, 60]}..." : prompt
          puts "    - id=#{image.id} label=#{image.label.inspect} prompt=#{prompt_preview.inspect}"
        end
      end
      puts ""
      puts "Estimated OpenAI cost: $#{format("%.2f", estimated_low)} – $#{format("%.2f", estimated_high)} (varies by model/size)"
      puts ""
      puts "Run without DRY_RUN to queue for real:"
      puts "  bin/rails classroom_boards:generate_images"
      next
    end

    puts "Queuing GenerateImageJob for #{pending.size} (image, board) pair(s) across #{new_boards.count} board(s)..."
    puts "  NOTE: GenerateImageJob calls OpenAI image generation — this incurs real API costs."
    puts "  Estimated cost: $#{format("%.2f", estimated_low)} – $#{format("%.2f", estimated_high)}"

    pending.each do |image, board|
      options = {
        "image_prompt" => image.image_prompt,
        "board_id" => board.id,
        "screen_size" => "lg",
        "transparent_bg" => true,
      }
      image.update_column(:status, "generating") if image.has_attribute?(:status)
      GenerateImageJob.perform_async(image.id, admin_id, options)
    end

    puts "Queued. Check Sidekiq for progress."
  end
end
