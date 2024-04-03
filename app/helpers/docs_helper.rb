module DocsHelper
  def mark_as_current_button(doc)
    if doc.is_a_favorite?(current_user)
      button_to "#{icon("fa-solid", "star")}".html_safe, mark_as_current_doc_path(doc), method: :patch, class: "absolute top-0 right-0 m-2 bg-white hover:text-blue-700 text-yellow-400 font-bold p-1 rounded"
      # button_to "#{icon("fa-solid", "star")}".html_safe, "#", class: "absolute top-0 right-0 m-4 bg-white text-yellow-400 font-bold p-1 rounded"
    else
      button_to "#{icon("fa-regular", "star")}".html_safe, mark_as_current_doc_path(doc), method: :patch, class: "absolute top-0 right-0 m-2 bg-white hover:text-blue-700 font-bold p-1 rounded"
    end
  end

  def display_doc_image(doc, classes = nil)
    classes ||= "shadow mx-auto my-auto"
    str = ""
    if !doc.image&.attached?
      str += "<div class='h-52 w-52 text-gray-400 text-2xl font-bold grid justify-items-center items-center shadow mx-auto my-auto'><span class='mx-auto my-auto'>#{doc.documentable.label&.upcase}</span></div>".html_safe
    else
      str += image_tag(doc.image, class: classes, data: { enlarge_target: "image" })
    end
    str.html_safe
  end

  def remove_doc_button(doc)
    # <%= button_to "Delete", doc, method: :delete, class: "absolute top-0 right-0 m-4 text-red-400 font-bold p-2 rounded" %>
    button_to trash_nav, doc, method: :delete, class: "absolute bottom-0 right-0 m-1 md:m-4 text-red-400 px-1 rounded bg-white"
  end
end
