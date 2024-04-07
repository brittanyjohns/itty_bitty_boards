class BetaRequestsController < ApplicationController
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

    respond_to do |format|
      if @beta_request.save
        format.html { redirect_to root_path, notice: "Thank you for your interest!  We will be in touch soon." }
        format.json { render :show, status: :created, location: @beta_request }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @beta_request.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /beta_requests/1 or /beta_requests/1.json
  def update
    respond_to do |format|
      if @beta_request.update(beta_request_params)
        format.html { redirect_to beta_request_url(@beta_request), notice: "BetaRequest was successfully updated." }
        format.json { render :show, status: :ok, location: @beta_request }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @beta_request.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /beta_requests/1 or /beta_requests/1.json
  def destroy
    @beta_request.destroy!

    respond_to do |format|
      format.html { redirect_to beta_requests_path, notice: "BetaRequest was successfully destroyed." }
      format.turbo_stream
    end
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_beta_request
    @beta_request = BetaRequest.find(params[:id])
  end

  def admin_only
    redirect_to root_path, alert: "You are not authorized to perform that action." unless current_user&.admin?
  end

  # Only allow a list of trusted parameters through.
  def beta_request_params
    params.require(:beta_request).permit(:email)
  end
end
