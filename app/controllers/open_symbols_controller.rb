class OpenSymbolsController < ApplicationController
  def index
    @symbols = OpenSymbol.includes(:docs).order(created_at: :desc).page(params[:page])
  end

  def show
    @symbol = OpenSymbol.find(params[:id])
  end

  def save_image
    @symbol = OpenSymbol.find(params[:id])
    @symbol.save_symbol_image
    redirect_back_or_to open_symbols_url, notice: "Image saved."
  end

  def make_image
    @symbol = OpenSymbol.find(params[:id])
    @symbol.add_to_matching_image
    redirect_back_or_to open_symbols_url, notice: "Image created."
  end

  def search
    @query = params[:query]

    @symbols = OpenSymbol.where("label ILIKE ?", "%#{params[:query]}%").order(created_at: :desc).page(params[:page])
  end

  def create
    query = params[:query]&.downcase
    response = OpenSymbol.search_symbols(query)

    if response
      symbols = JSON.parse(response)
      puts "Creating symbols...#{symbols.count}"
      limit = 5
      puts "Limiting to #{limit} symbols"
      count = 0
      symbols.each do |symbol|
        existing_symbol = OpenSymbol.find_by(original_os_id: symbol["id"], name: symbol["name"]&.downcase)
        if existing_symbol || OpenSymbol::IMAGE_EXTENSIONS.exclude?(symbol["extension"])
          puts "Symbol already exists: #{existing_symbol&.id} Or not an image: #{symbol["extension"]}"
          next
        end
        break if count >= limit
        new_symbol =
          OpenSymbol.create!(
            name: symbol["name"],
            image_url: symbol["image_url"],
            label: query,
            search_string: symbol["search_string"],
            symbol_key: symbol["symbol_key"],
            locale: symbol["locale"],
            license_url: symbol["license_url"],
            license: symbol["license"],
            original_os_id: symbol["id"],
            repo_key: symbol["repo_key"],
            unsafe_result: symbol["unsafe_result"],
            protected_symbol: symbol["protected_symbol"],
            use_score: symbol["use_score"],
            relevance: symbol["relevance"],
            extension: symbol["extension"],
            enabled: symbol["enabled"],
          )
        count += 1
      end
    end

    redirect_to search_open_symbols_url(query: query), notice: "Symbols created."
  end
end
