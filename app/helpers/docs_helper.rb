module DocsHelper
  def mark_as_current_button(doc)
    if doc.current
      button_to "#{icon("fa-solid", "star")}".html_safe, "#", class: "absolute top-0 right-0 m-4 text-yellow-400 font-bold p-2 rounded"
    else
      button_to "#{icon("fa-regular", "star")}".html_safe, mark_as_current_doc_path(doc), method: :patch, class: "absolute top-0 right-0 m-4 text-blue-500 hover:text-blue-700font-bold p-2 rounded"
    end
  end

  def display_doc_image(doc, classes = nil)
    classes ||= "shadow mx-auto my-auto"
    str = ""
    if !doc.image&.attached?
      str += "<div class='h-52 w-52 text-gray-400 text-2xl font-bold grid justify-items-center items-center shadow mx-auto my-auto'><span class='mx-auto my-auto'>#{image.label.upcase}</span></div>".html_safe
    else
      str += image_tag(doc.image.representation(resize_to_limit: [500, 500]).processed.url, class: classes, data: { enlarge_target: "image" })
    end
    str.html_safe
  end

  def remove_doc_button(doc)
    # <%= button_to "Delete", doc, method: :delete, class: "absolute top-0 right-0 m-4 text-red-400 font-bold p-2 rounded" %>
    button_to "#{icon("fa-solid", "trash")}".html_safe, doc, method: :delete, class: "absolute top-0 left-0 m-4 text-red-400 font-bold p-2 rounded"
  end
end
