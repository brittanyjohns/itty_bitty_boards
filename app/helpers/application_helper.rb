module ApplicationHelper

    def edit_button_for(model)
        link_to "Edit", edit_polymorphic_path(model), class: "btn btn-primary"
    end

    def delete_button_for(model)
        link_to "Delete", polymorphic_path(model), method: :delete, data: { confirm: "Are you sure?" }, class: "btn btn-danger"
    end

    def coffee_link
    #     <div class="flex justify-center p-2 border hover:cursor-pointer focus:shadow-outline">
    # <p class="text-center mr-3">Donate to support the site</p>
    # <a href="https://www.buymeacoffee.com/bhannajohns" target="_blank" class="flex items-center justify-center bg-indigo-500 hover:bg-indigo-600 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-opacity-50 rounded-lg p-2">
        # link_to coffee_nav, "https://www.buymeacoffee.com/bhannajohns", class: "btn btn-primary", data: {tippy_content: "Buy me a coffee (Donate to the cause)"}
        # str = "<div class='flex justify-center p-2 border hover:cursor-pointer focus:shadow-outline'>"
        # str += "<p class='text-center mr-3'>Donate to support the site</p>"
        # str += "<a href='https://www.buymeacoffee.com/bhannajohns' target='_blank' class='flex items-center justify-center bg-indigo-500 hover:bg-indigo-600 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-opacity-50 rounded-lg p-2'>"
        # str += coffee_nav
        # str += "</a>"
        # str += "</div>"
        # str.html_safe
        link_to "https://www.buymeacoffee.com/bhannajohns", target: "_blank", class: "flex items-center justify-center text-white bg-indigo-500 hover:bg-indigo-600 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-opacity-50 rounded-lg p-2", data: {tippy_content: "Buy me a coffee (Donate to the cause)"} do
            # <p class='text-center mr-3'>Donate to support the site</p>
            content_tag(:p, "Donate to support the site", class: "text-center mr-3") +
            coffee_nav
        end
    end
end
