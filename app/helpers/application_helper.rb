module ApplicationHelper

    def edit_button_for(model)
        link_to "Edit", edit_polymorphic_path(model), class: "btn btn-primary"
    end

    def delete_button_for(model)
        link_to "Delete", polymorphic_path(model), method: :delete, data: { confirm: "Are you sure?" }, class: "btn btn-danger"
    end
    def github_nav
        link_to "https://github.com/brittanyjohns", target: "_blank", class: "flex items-center justify-center text-white bg-indigo-500 hover:bg-indigo-600 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-opacity-50 rounded-lg p-2", data: {tippy_content: "GitHub"} do
            # <p class='text-center mr-3'>Donate to support the site</p>
            content_tag(:p, "GitHub", class: "text-center mr-3") +
            '<i class="fa-brands fa-github"></i>'.html_safe
        end 
    end

    def coffee_link
        link_to "https://www.buymeacoffee.com/bhannajohns", target: "_blank", class: "flex items-center justify-center text-white bg-indigo-500 hover:bg-indigo-600 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-opacity-50 rounded-lg my-2 py-5 w-3/4 md:w-2/3 mx-auto px-2", data: {tippy_content: "Buy me a coffee (Donate to the site)"} do
            content_tag(:p, "Donate to support the site", class: "text-center mx-3") +
            coffee_nav
        end
    end

end
