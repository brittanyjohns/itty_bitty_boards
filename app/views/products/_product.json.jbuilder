json.extract! product, :id, :name, :price, :active, :product_category_id, :description, :created_at, :updated_at
json.url product_url(product, format: :json)
