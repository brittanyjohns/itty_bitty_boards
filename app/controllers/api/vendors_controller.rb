class API::VendorsController < API::ApplicationController
  def index
    @vendors = Vendor.all
    render json: @vendors.map { |vendor| vendor.api_view(current_user) }
  end

  def search
    query = params[:query]
    if query.present?
      @vendors = Vendor.where("business_name ILIKE ?", "%#{query}%")
    else
      @vendors = Vendor.all
    end
    render json: @vendors.map { |vendor| vendor.api_view(current_user) }
  end

  def show
    @vendor = Vendor.find(params[:id])
    render json: @vendor.api_view(current_user)
  end

  def create
    @vendor = Vendor.create_from_email(
      params[:user_email],
      params[:business_name],
      params[:business_email],
      params[:website]
    )
    location = params[:location]
    category = params[:category]
    if location.present?
      @vendor.location = location
    end
    if category.present?
      @vendor.category = category
    end
    if @vendor
      render json: @vendor.api_view(current_user), status: :created
    else
      render json: { error: "Failed to create vendor" }, status: :unprocessable_entity
    end
  end

  def generate
    email = params[:user_email]
    business_name = params[:business_name]
    if email.blank? || business_name.blank?
      render json: { error: "Email and business name are required" }, status: :unprocessable_entity
      return
    end
    @vendor = Vendor.create_from_email(email, business_name, params[:business_email], params[:website])
    if @vendor
      render json: @vendor.api_view(current_user), status: :created
    else
      render json: { error: "Failed to generate vendor" }, status: :unprocessable_entity
    end
  end

  def update
    @vendor = Vendor.find(params[:id])
    if @vendor.update(vendor_params)
      render json: @vendor.api_view(current_user)
    else
      render json: @vendor.errors, status: :unprocessable_entity
    end
  end

  private

  def vendor_params
    params.require(:vendor).permit(:business_name, :business_email, :website, :location, :category, :verified, :description, configuration: {})
  end
end
