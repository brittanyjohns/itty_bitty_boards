module ImagesHelper
    def display_image_for(image, user)
      user_image = image.display_image(user)
        str = ""
        if !user_image
          str += image_tag("https://via.placeholder.com/300x300.png?text=#{image.label_param}", class: "shadow mx-auto my-auto h-fit")
          # str += "<div class='w-100 h-100 px-2 text-gray-400 text-md font-bold grid justify-items-center items-center shadow mx-auto my-auto'><span class='mx-auto my-auto'>#{image.label&.upcase.truncate(27, separator: ' ')}</span> #{image.generating? ? loading_spinner : ""}</div>".html_safe
        else
          str += image_tag(user_image.representation(resize_to_limit: [300, 300]).processed.url, class: "shadow mx-auto my-auto h-fit")
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
        button_to "#{icon("fa-solid", "trash")}".html_safe, remove_image_board_path(board, image_id: image.id), class: "text-red-600 hover:text-red-700 py-1 px-1 rounded-full absolute bottom-0 right-0 m-1 mr-2", method: :post
      end

      def loading_spinner
        "<div class='flex justify-center mb-5 p-6 rounded-full text-green-600 p-2 loading_spinner'><span class='animate-spin rounded-full h-8 w-8 border-t-2 border-b-2 border-green-600'></span> <span class='ml-2 my-auto'>Generating image...</span></div>".html_safe
      end

      def print_image_info(image)
        str = ""
        str += "<div class='text-sm text-gray-500 bg-gray-100 p-2 rounded-lg shadow w-64'>"
        str += "<div>id: #{image.id}</div>"
        str += "<div>status: #{image.status}</div>"
        str += "<div>user_id: #{image.user_id}</div>"
        str += "<div>label: #{image.label}</div>"
        str += "<div>private: #{image.private}</div>"
        str += "<div>docs: #{image.docs.count}</div>"
        str += "<div>type: #{image.image_type}</div>"
        str += "<div>created_at: #{image.created_at}</div>"
        str += "<div>updated_at: #{image.updated_at}</div>"
        str += "</div>"
        str.html_safe
      end
end
