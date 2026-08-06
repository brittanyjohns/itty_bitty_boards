module Admin
  class OrganizationsController < Admin::ApplicationController
    def index
      @organizations = Organization.order(created_at: :desc)
    end

    def show
      @organization = Organization.find(params[:id])
      @member_search = params[:member_search]
      @members = @organization.users.order(:email)
      @members = @members.where("email ILIKE ? OR name ILIKE ?", "%#{@member_search}%", "%#{@member_search}%") if @member_search.present?
    end

    def new
      @organization = Organization.new
    end

    def create
      @organization = Organization.new(organization_params)
      if @organization.save
        redirect_to admin_dashboard_organization_path(@organization), notice: "Organization created."
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit
      @organization = Organization.find(params[:id])
    end

    def update
      @organization = Organization.find(params[:id])
      if @organization.update(organization_params)
        redirect_to admin_dashboard_organization_path(@organization), notice: "Organization updated."
      else
        render :edit, status: :unprocessable_content
      end
    end

    def assign_user
      @organization = Organization.find(params[:id])
      user_email = params[:user_email]

      user = User.invite!(email: user_email, skip_invitation: true)
      # invite! always returns a User instance — for an already-registered
      # email it resolves to that existing (persisted) record with a stale
      # "already taken" error attached, which we intentionally ignore here.
      if user.persisted?
        inviting_user_id = @organization.admin_user_id
        if inviting_user_id
          user.invited_by_id = inviting_user_id
          user.invited_by_type = "User"
          user.send_welcome_to_organization_email(@organization)
        end
        user.stripe_customer_id = User.create_stripe_customer(user_email)
        user.organization_id = @organization.id
        user.save
        redirect_to admin_dashboard_organization_path(@organization), notice: "#{user_email} added to #{@organization.name}."
      else
        redirect_to admin_dashboard_organization_path(@organization), alert: user.errors.full_messages.to_sentence
      end
    end

    private

    def organization_params
      params.require(:organization).permit(:name, :slug, :admin_user_id)
    end
  end
end
