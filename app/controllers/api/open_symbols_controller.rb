class API::OpenSymbolsController < API::ApplicationController
  skip_before_action :authenticate_token!

  def search_api
    Rails.logger.info "Searching Open Symbols for query: #{params[:query]}"
    @query = params[:query]
    @search_results = OpenSymbol.search_symbols(@query)
    if @search_results
      @symbols = JSON.parse(@search_results)
      totalResults = @symbols.length
      render json: { symbols: @symbols, totalResults: totalResults }, status: :ok
    else
      render json: { error: "Failed to fetch symbols" }, status: :internal_server_error
    end
  end

  def create
    image_url = params[:image_url]
    board_image_id = params[:board_image_id]
    @symbol = OpenSymbol.create_symbol_from_image_url(image_url, board_image_id)
    if @symbol.persisted?
      render json: @symbol, status: :created
    else
      render json: { errors: @symbol.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # def create
  #   query = params[:query]&.downcase
  #   response = OpenSymbol.search_symbols(query)

  #   if response
  #     symbols = JSON.parse(response)
  #     puts "Creating symbols...#{symbols.count}"
  #     limit = 5
  #     puts "Limiting to #{limit} symbols"
  #     count = 0
  #     symbols.each do |symbol|
  #       existing_symbol = OpenSymbol.find_by(original_os_id: symbol["id"], name: symbol["name"]&.downcase)
  #       if existing_symbol || OpenSymbol::IMAGE_EXTENSIONS.exclude?(symbol["extension"])
  #         puts "Symbol already exists: #{existing_symbol&.id} Or not an image: #{symbol["extension"]}"
  #         next
  #       end
  #       break if count >= limit
  #       new_symbol =
  #         OpenSymbol.create!(
  #           name: symbol["name"],
  #           image_url: symbol["image_url"],
  #           label: query,
  #           search_string: symbol["search_string"],
  #           symbol_key: symbol["symbol_key"],
  #           locale: symbol["locale"],
  #           license_url: symbol["license_url"],
  #           license: symbol["license"],
  #           original_os_id: symbol["id"],
  #           repo_key: symbol["repo_key"],
  #           unsafe_result: symbol["unsafe_result"],
  #           protected_symbol: symbol["protected_symbol"],
  #           use_score: symbol["use_score"],
  #           relevance: symbol["relevance"],
  #           extension: symbol["extension"],
  #           enabled: symbol["enabled"],
  #         )
  #       count += 1
  #     end
  #   end
  # end
end
