module ImagesHelper
    def display_image_for(image)
        str = ""
        if !image.display_image
          str += "<div class='h-52 w-52 text-gray-400 text-2xl font-bold grid justify-items-center items-center shadow mx-auto my-auto'><span class='mx-auto my-auto'>#{image.label.upcase}</span></div>".html_safe
        else
          str += image_tag(image.display_image.representation(resize_to_limit: [208, 208]).processed.url, class: "shadow mx-auto my-auto")
        end
        if @board.present? && @board.images.include?(image)
          str += button_to "#{icon("fa-solid", "trash")}".html_safe, remove_image_board_path(@board, image_id: image.id), class: "text-red-600 hover:text-red-700 py-1 px-1 float-right", method: :post
        end
        str.html_safe
      end
      def generate_image_button(image)
        button_to "#{icon("fa-regular", "image")} CREATE Image".html_safe, generate_image_path(image), class: "rounded-full", method: :post
      end
    
      def remove_image_button(board, image)
        button_to "#{icon("fa-solid", "trash")}".html_safe, remove_image_board_path(board, image_id: image.id), class: "text-red-600 hover:text-red-700 py-1 px-1 rounded-full absolute bottom-0 left-0", method: :post
      end
end
