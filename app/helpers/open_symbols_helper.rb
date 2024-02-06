module OpenSymbolsHelper
    def search_string_list(str)
        list = ""
        str.split(",").map(&:strip).each do |s|
            list += "<li>#{s}</li>" unless s.blank?
        end
        list.html_safe
    end
end
