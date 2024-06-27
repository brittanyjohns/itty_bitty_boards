class API::BetaRequestsController < API::ApplicationController
  before_action :set_beta_request, only: %i[ show edit update destroy ]
  before_action :admin_only, only: %i[ index edit update destroy ]

  # GET /beta_requests or /beta_requests.json
  def index
    @beta_requests = BetaRequest.all
    @beta_request = BetaRequest.new
  end

  # GET /beta_requests/1 or /beta_requests/1.json
  def show
  end

  # GET /beta_requests/new
  def new
    @beta_request = BetaRequest.new
  end

  # GET /beta_requests/1/edit
  def edit
  end

  # POST /beta_requests or /beta_requests.json
  def create
    @beta_request = BetaRequest.new(beta_request_params)
    render json: { success: @beta_request.save ? @beta_request.persisted? : @beta_request.errors }, status: @beta_request.save ? :created : :unprocessable_entity
  end

  # PATCH/PUT /beta_requests/1 or /beta_requests/1.json
  def update
    respond_to do |format|
      if @beta_request.update(beta_request_params)
        format.json { render :show, status: :ok, location: @beta_request }
      else
        format.json { render json: @beta_request.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /beta_requests/1 or /beta_requests/1.json
  def destroy
    @beta_request.destroy!
    render json: { success: true }
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_beta_request
    @beta_request = BetaRequest.find(params[:id])
  end

  def admin_only
    # redirect_to root_path, alert: "You are not authorized to perform that action." unless current_user&.admin?
    render json: { error: "You are not authorized to perform that action." }, status: :unauthorized unless current_user&.admin
  end

  # Only allow a list of trusted parameters through.
  def beta_request_params
    params.require(:beta_request).permit(:email)
  end
end
