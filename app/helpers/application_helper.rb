module ApplicationHelper

    def edit_button_for(model)
        link_to "Edit", edit_polymorphic_path(model), class: "btn btn-primary"
    end

    def delete_button_for(model)
        link_to "Delete", polymorphic_path(model), method: :delete, data: { confirm: "Are you sure?" }, class: "btn btn-danger"
    end
end
