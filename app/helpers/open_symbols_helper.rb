module OpenSymbolsHelper
  def search_string_list(str)
    list = ""
    str.split(",").map(&:strip).each do |s|
      list += "<li>#{s}</li>" unless s.blank?
    end
    list.html_safe
  end

  def symbol_image(symbol)
    if symbol.image&.attached? && symbol.image.representable?
      image_tag symbol.image.url, class: "img-fluid"
    else
      image_tag symbol.image_url, class: "w-1/4"
    end
  end
end
