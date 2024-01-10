module ImagesHelper
    def display_image_for(image, user)
      user_image = image.display_image(user)
        str = ""
        if !user_image&.attached?
          str += "<div class='w-100 h-100 text-gray-400 text-2xl font-bold grid justify-items-center items-center shadow mx-auto my-auto'><span class='mx-auto my-auto'>#{image.label.upcase}</span></div>".html_safe
        else
          str += image_tag(image.display_image.representation(resize_to_limit: [300, 300]).processed.url, class: "shadow mx-auto my-auto")
        end
        if @board.present? && @board.images.include?(image) && user.can_edit?(@board)
          str += button_to "#{icon("fa-solid", "trash")}".html_safe, remove_image_board_path(@board, image_id: image.id), class: "text-red-600 hover:text-red-700 py-1 px-1 float-right", method: :post
        end
        puts "str: #{str}\n"
        str.html_safe
      end
      def generate_image_button(image)
        button_to "Generate AI Image", generate_image_path(image), method: :post, class: "bg-green-600 hover:tbgext-green-700 p-3 m-2 rounded-lg text-white", 
        form: {data: {controller: 'disable'}}, data: {disable_target: "button", action: "click->disable#disableForm"} 
      end
    
      def remove_image_button(board, image)
        button_to "#{icon("fa-solid", "trash")}".html_safe, remove_image_board_path(board, image_id: image.id), class: "text-red-600 hover:text-red-700 py-1 px-1 rounded-full absolute bottom-0 left-0", method: :post
      end
end
