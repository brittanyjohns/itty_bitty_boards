module ImagesHelper
    def display_image_for(image, user)
      user_image = image.display_image(user)
        str = ""
        if !user_image&.attached?
          str += "<div class='w-100 h-100 px-2 text-gray-400 text-md font-bold grid justify-items-center items-center shadow mx-auto my-auto'><span class='mx-auto my-20'>#{image.label&.upcase.truncate(27, separator: ' ')}</span></div>".html_safe
        else
          str += image_tag(user_image.representation(resize_to_limit: [300, 300]).processed.url, class: "shadow mx-auto my-auto")
        end
        # if @board.present? && @board.images.include?(image) && user.can_edit?(@board)
        #   str += button_to "#{icon("fa-solid", "trash")}".html_safe, remove_image_board_path(@board, image_id: image.id), class: "text-red-600 hover:text-red-700 py-1 px-1 float-right", method: :post,  form: {data: {turbo: 'false'}}
        # end
        str.html_safe
      end

      def generate_image_button(image)
        button_to "Generate AI Image", generate_image_path(image), method: :post, class: "bg-green-600 hover:text-green-700 p-3 m-2 rounded-lg text-white", 
        form: {data: {controller: 'disable'}}, data: {disable_target: "button", action: "click->disable#disableForm"} 
      end
    
      def remove_image_button(board, image)
        return unless board && image
        button_to "#{icon("fa-solid", "trash")}".html_safe, remove_image_board_path(board, image_id: image.id), class: "text-red-600 hover:text-red-700 py-1 px-1 rounded-full absolute bottom-0 right-0 m-2 mr-3", method: :post
      end
end
