module DocsHelper
  def mark_as_current_button(doc)
    if doc.current
      button_to "#{icon("fa-solid", "star")}".html_safe, "#", class: "absolute top-0 right-0 m-4 text-yellow-400 font-bold p-2 rounded"
    else
      button_to "#{icon("fa-regular", "star")}".html_safe, mark_as_current_doc_path(doc), method: :patch, class: "absolute top-0 right-0 m-4 text-blue-500 hover:text-blue-700font-bold p-2 rounded"
    end
  end

  def remove_doc_button(doc)
    # <%= button_to "Delete", doc, method: :delete, class: "absolute top-0 right-0 m-4 text-red-400 font-bold p-2 rounded" %>
    button_to "#{icon("fa-solid", "trash")}".html_safe, doc, method: :delete, class: "absolute top-0 right-0 m-4 text-red-400 font-bold p-2 rounded"
  end
end
