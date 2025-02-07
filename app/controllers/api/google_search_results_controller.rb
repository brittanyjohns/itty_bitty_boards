class API::GoogleSearchResultsController < API::ApplicationController
  # skip_before_action :authenticate_token!
  # before_action :authenticate_signed_in!
  before_action :validate_search_params, only: [:image_search, :next_page]
  before_action :initialize_search_service, only: [:image_search, :next_page]

  def image_search
    add_optional_params

    if @image_search_service.search
      render json: @image_search_service.images_api_view
    else
      render_error_response
    end
  end

  def next_page
    @image_search_service.add_params(start: params[:start]) if params[:start].present?

    if @image_search_service.search
      render json: {
        images: @image_search_service.images_api_view,
        queries: @image_search_service.queries,
        nextStartIndex: @image_search_service.nextStartIndex,
      }
    else
      render_error_response
    end
  end

  private

  def initialize_search_service
    query = params[:q]
    secondarySearch = params[:secondarySearch]
    if secondarySearch.present?
      query_to_run = secondarySearch
    else
      query_to_run = query
    end

    puts "query_to_run: #{query_to_run}"

    @image_search_service = GoogleResultsService.new(query_to_run, params[:start] || 1)
  end

  def add_optional_params
    %i[imgType rights safe orTerms imgColorType language].each do |param|
      @image_search_service.add_params(param => params[param]) if params[param].present?
    end
  end

  def validate_search_params
    render json: { error: "Query parameter is required" }, status: :bad_request unless params[:q].present?
  end

  def render_error_response
    render json: { error: "Failed to fetch search results" }, status: :internal_server_error
  end
end
