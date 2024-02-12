module ApplicationHelper

    def edit_button_for(model)
        link_to "Edit", edit_polymorphic_path(model), class: "btn btn-primary"
    end

    def delete_button_for(model)
        link_to "Delete", polymorphic_path(model), method: :delete, data: { confirm: "Are you sure?" }, class: "btn btn-danger"
    end
    def github_nav
        "<svg xmlns='http://www.w3.org/2000/svg' class='h-6 w-6' fill='none' viewBox='0 0 24 24' stroke='currentColor'>
        <path stroke-linecap='round' stroke-linejoin='round' stroke-width='2' d='M9 19V21M9 21H7M9 21H15M9 21H15M5 21H3C2.44772 21 2 20.5523 2 20V4C2 3.44772 2.44772 3 3 3H21C21.5523 3 22 3.44772 22 4V20C22 20.5523 21.5523 21 21 21H19M17 21V19M17 21H19M17 21H7M17 21H15M12 3V15' />
        </svg>".html_safe
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
        str = link_to "https://www.buymeacoffee.com/bhannajohns", target: "_blank", class: "flex items-center justify-center text-white bg-indigo-500 hover:bg-indigo-600 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-opacity-50 rounded-lg p-2", data: {tippy_content: "Buy me a coffee (Donate to the cause)"} do
            # <p class='text-center mr-3'>Donate to support the site</p>
            content_tag(:p, "Donate to support the site", class: "text-center mr-3") +
            coffee_nav
        end
        str += "<hr>".html_safe
        str += link_to "https://github.com/brittanyjohns", target: "_blank", class: "flex items-center justify-center text-white bg-indigo-500 hover:bg-indigo-600 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-opacity-50 rounded-lg p-2", data: {tippy_content: "GitHub"} do
            # <p class='text-center mr-3'>Donate to support the site</p>
            content_tag(:p, "GitHub", class: "text-center mr-3") +
            github_nav
        end
        str.html_safe
    end
end
