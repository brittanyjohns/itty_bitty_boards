class BetaRequestsController < ApplicationController
  before_action :restrict, only: %i[ show edit update destroy index ]
  before_action :set_beta_request, only: %i[ show edit update destroy ]

  # GET /beta_requests or /beta_requests.json
  def index
    @beta_requests = BetaRequest.all
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
    unless params[:beta_request][:email].present?
      flash[:error] = "Email can't be blank"
      redirect_to root_path
      return
    end
    @beta_request = BetaRequest.new(beta_request_params) 
    puts "Beta request params: #{beta_request_params}"  
    respond_to do |format|
      if @beta_request.save
        format.html { redirect_to @beta_request, notice: "Thank you for your interest in our beta! We'll be in touch soon!", status: :created }
        format.json { render :show, status: :created, location: @beta_request }
        format.turbo_stream { render turbo_stream: turbo_stream.replace('beta_request_form', partial: 'main/beta_request_form', locals: { beta_request: BetaRequest.new }) }
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
        format.html { redirect_to beta_request_url(@beta_request), notice: "Beta request was successfully updated." }
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
      format.html { redirect_to beta_requests_url, notice: "Beta request was successfully destroyed." }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_beta_request
      @beta_request = BetaRequest.find(params[:id])
    end

    def restrict
      redirect_to root_path unless current_user&.admin?
    end

    # Only allow a list of trusted parameters through.
    def beta_request_params
      params.require(:beta_request).permit(:email)
    end
end
