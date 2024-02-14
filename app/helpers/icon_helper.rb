module IconHelper
    def shopping_cart_nav(tooltip_text = "View Cart")
        "<i class='fa-solid fa-cart-shopping fa-lg' data-tippy-content='#{tooltip_text}' }></i>".html_safe
    end

    def contact_nav(tooltip_text = "Contact Us")
        "<i class='fa-solid fa-envelope fa-lg' data-tippy-content='#{tooltip_text}' }></i>".html_safe
    end

    def coins_nav(tooltip_text = "Buy Tokens")
        "<i class='fa-solid fa-money-bill-1 fa-lg' data-tippy-content='#{tooltip_text}' }></i>".html_safe
    end

    def user_nav(tooltip_text = "Dashboard")
        "<i class='fa-solid fa-user fa-lg'}></i>".html_safe
    end

    def copy_nav(tooltip_text = "Copy")
        "<i class='fa-solid fa-copy fa-lg' data-tippy-content='#{tooltip_text}' }></i>".html_safe
    end

    def home_nav(tooltip_text = "Home")
        "<i class='fa-solid fa-home fa-lg' data-tippy-content='#{tooltip_text}' }></i>".html_safe
    end

    def menu_nav(tooltip_text = "Menus")
        "<i class='fa-solid fa-apple-whole fa-lg' data-tippy-content='#{tooltip_text}' }></i>".html_safe
    end

    def image_nav(tooltip_text = "Images")
        "<i class='fa-solid fa-images fa-lg' data-tippy-content='#{tooltip_text}' }></i>".html_safe
    end

    def board_nav(tooltip_text = "Boards")
        "<i class='fa-solid fa-chess-board fa-lg' data-tippy-content='#{tooltip_text}' }></i>".html_safe
    end

    def new_board_nav(tooltip_text = "New Board")
        "<i class='fa-solid fa-square-plus fa-lg' data-tippy-content='#{tooltip_text}' }></i>".html_safe
    end

    def new_image_nav(tooltip_text = "New Image")
        "<i class='fa-solid fa-image fa-lg' data-tippy-content='#{tooltip_text}' }></i>".html_safe
    end

    def new_menu_nav(tooltip_text = "New Menu")
        "<i class='fa-solid fa-pizza-slice fa-lg' data-tippy-content='#{tooltip_text}' }></i>".html_safe
    end

    def tokens_nav(tooltip_text = "Tokens")
        "<i class='fa-solid fa-coins fa-lg'></i>".html_safe
    end

    def trash_nav(tooltip_text = "Delete", size = "sm")
        "<i class='fa-solid fa-trash fa-#{size}' data-tippy-content='#{tooltip_text}' }></i>".html_safe
    end

    def coffee_nav(size = "sm")
        "<i class='fa-solid fa-coffee fa-#{size}'></i>".html_safe
    end

    def logout_nav(tooltip_text = "Logout", size = "lg")
        "<i class='fa-solid fa-sign-out fa-#{size}' data-tippy-content='#{tooltip_text}' }></i>".html_safe
    end

    def login_nav(tooltip_text = "Login", size = "lg")
        "<i class='fa-solid fa-sign-in fa-#{size}' data-tippy-content='#{tooltip_text}' }></i>".html_safe
    end

    def change_image_icon(display_text = "Change Image", size = "sm")
        "<i class='fa-solid fa-pen-to-square fa-#{size}'></i> <span class='text-xs'>#{display_text}</span>".html_safe
    end

    def spinner
        "<span class='animate-spin rounded-full h-32 w-32 border-t-2 border-b-2 border-white'></span>".html_safe
    end
end