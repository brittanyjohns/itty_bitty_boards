class GenerateImageJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: false

  def perform(image_id, user_id=nil, *args)

    image = Image.find(image_id)
    image.update(status: "generating") unless image.status == "generating"
    if args.present?
      image_prompt = args[0]
      image.temp_prompt = image_prompt
    end
    begin
      image.create_image_doc(user_id)
      if image.menu? && image.image_prompt.include?(Menu::PROMPT_ADDITION)
        image.image_prompt = image.image_prompt.gsub(Menu::PROMPT_ADDITION, "")
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
