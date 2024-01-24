class GenerateImageJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: false

  def perform(image_id, user_id=nil, *args)
    puts "**** GenerateImageJob - perform **** \n image_id: #{image_id}\n user_id: #{user_id}\n"

    image = Image.find(image_id)
    image.update(status: "generating")
    if args.present?
      image_prompt = args[0]
      puts "Updating image_prompt to: #{image_prompt}\n"
      image.temp_prompt = image_prompt
    end
    begin
      image.create_image_doc(user_id)
      puts "CREATE IMAGE: #{image.inspect}\n"
      if image.menu? && image.image_prompt.include?(Menu::PROMPT_ADDITION)
        puts "**** Updating image_prompt **** \n"
        image.display_description = image.image_prompt
        image.image_prompt = image.image_prompt.gsub(Menu::PROMPT_ADDITION, "")
        puts "\n\nUPDATED IMAGE: #{image.inspect}\n\n"
        image.save!
      end
    rescue => e
      puts "**** ERROR **** \n#{e.message}\n"
      image.update(status: "error", error: e.message)
      puts "UPDATE IMAGE: #{image.inspect}"
    end
    # Do something
  end
end
