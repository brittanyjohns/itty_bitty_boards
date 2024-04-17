module ImagesHelper
  def display_image_for(image, user, size = 300, additional_classes = "")
    user_image = image.display_image(user)
    str = ""
    if !user_image
      str += image_tag("https://via.placeholder.com/#{size}x#{size}.png?text=#{image.label_param}", class: "shadow mx-auto my-auto h-fit #{additional_classes}")
      # str += "<div class='w-100 h-100 px-2 text-gray-400 text-md font-bold grid justify-items-center items-center shadow mx-auto my-auto'><span class='mx-auto my-auto'>#{image.label&.upcase.truncate(27, separator: ' ')}</span> #{image.generating? ? loading_spinner : ""}</div>".html_safe
    else
      url_for_image = url_for(user_image)
      str += image_tag(url_for_image, class: "shadow mx-auto my-auto h-fit #{additional_classes}")

      # str += image_tag(user_image, class: "shadow mx-auto my-auto h-fit")
    end
    str.html_safe
  end

  def generate_image_button(image)
    button_to "Generate AI Image", generate_image_path(image), method: :post, class: "bg-green-600 hover:text-green-700 p-3 m-2 rounded-lg text-white",
                                                               form: { data: { controller: "disable" } }, data: { disable_target: "button", action: "click->disable#disableForm" }
  end

  def display_image_for_locked_board(image, user)
    user_image = image.display_image(user)
    str = ""
    if !user_image
      str += image_tag("https://via.placeholder.com/300x300.png?text=#{image.label_param}", class: "absolute object-contain w-full h-full top-0 left-0", data: { speak_target: "speaker" })
    else
      str += image_tag(image.display_image(user), class: "absolute object-contain w-full h-full top-0 left-0", data: { resize_target: "image", speak_target: "speaker" })
    end
    str.html_safe
  end

  def remove_image_button(board, image)
    return unless board && image
    button_to trash_nav, remove_image_board_path(board, image_id: image.id), class: "text-red-600 hover:text-red-700 py-1 px-1 rounded-full absolute bottom-0 right-0 m-1 mr-2", method: :post, data: { turbo_confirm: "Are you sure you want to remove this image from the board?" }
  end

  def loading_spinner
    "<div class='flex justify-center mb-5 p-6 rounded-full text-green-600 p-2 loading_spinner'><span class='animate-spin rounded-full h-8 w-8 border-t-2 border-b-2 border-green-600'></span> <span class='ml-2 my-auto'>Generating image...</span></div>".html_safe
  end

  def print_image_info(image)
    str = ""
    str += "<div class='text-sm text-gray-500 bg-gray-100 p-2 rounded-lg shadow w-64'>"
    str += "<div>id: #{image.id}</div>"
    str += "<div>status: #{image.status}</div>"
    str += "<div>open symbol status: #{image.open_symbol_status}</div>"
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

  def print_doc_info(doc)
    str = ""
    str += "<div class='text-sm text-gray-500 bg-gray-100 p-2 rounded-lg shadow w-64'>"
    str += "<div>id: #{doc.id}</div>"
    str += "<div>image_id: #{doc.documentable_type} #{doc.documentable_id}</div>"
    str += "<div>user_id: #{doc.user_id}</div>"
    str += "<div>processed: #{doc.processed}</div>"
    str += "<div>created_at: #{doc.created_at}</div>"
    str += "<div>updated_at: #{doc.updated_at}</div>"
    str += "</div>"
    str.html_safe
  end

  def get_audio_list_with_voice_names(image)
    audio_files = image.audio_files
    str = "<div class='h-48 overflow-scroll'>"
    # audio_files.map { |audio| audio.filename.to_s.split("_").second }
    # audio_tag audio_file, controls: true, class: "my-2 flex flex-col audio-player"

    audio_files.each do |audio|
      voice = audio.filename.to_s.split("_").second&.upcase
      str += "<div class='flex justify-center mb-2'>"
      str += "<p class='font-bold text-center my-auto mr-2'>#{voice}</p>"

      str += audio_tag audio, controls: true, class: ""
      str += button_to trash_nav, remove_audio_image_path(image, audio_id: audio.id), method: :delete, data: { confirm: "Are you sure?" }, class: "text-red-600 hover:text-red-700 py-1 px-1 rounded-full"

      str += "</div>"
    end
    str += "</div>"
    str.html_safe
  end

  def audio_tag_for_image(image, board, class_name = "", controls = true)
    if image.get_voice_for_board(board).nil?
      return audio_tag("", controls: false, id: "audio-#{image.label.parameterize}", class: "hidden", data: { speak_target: "audio" })
    end
    audio_tag(polymorphic_path(image.get_voice_for_board(board)),
              controls: false, id: "audio-#{image.label.parameterize}",
              class: "hidden", data: { speak_target: "audio" })
  end
end
