module Admin
  # Scene mockups of a PrintableProduct's own artwork. Everything but the owner
  # and its routes is Admin::SceneCompositionsController, views included — so a
  # product and a board printable pick templates, validate art and enqueue renders
  # through one piece of code.
  class PrintableProductSceneCompositionsController < Admin::SceneCompositionsController
    private

    def set_owner
      @owner = @product = PrintableProduct.find(params[:dashboard_printable_product_id])
    end

    def owner_heading
      [@owner.name, @owner.size_label.presence, "product ##{@owner.id}"].compact.join(" · ")
    end

    def owner_path = admin_dashboard_printable_product_path(@owner)
    def compositions_path_for_owner = admin_dashboard_printable_product_scene_compositions_path(@owner)
    def composition_path_for(composition) = admin_dashboard_printable_product_scene_composition_path(@owner, composition)
    def edit_composition_path_for(composition) = edit_admin_dashboard_printable_product_scene_composition_path(@owner, composition)
    def new_composition_path_for(**query) = new_admin_dashboard_printable_product_scene_composition_path(@owner, query)
    def render_composition_path_for(composition) = render_scene_admin_dashboard_printable_product_scene_composition_path(@owner, composition)

    # A product has no Etsy listings yet (a follow-up adds them).
    def listing_param = nil
  end
end
