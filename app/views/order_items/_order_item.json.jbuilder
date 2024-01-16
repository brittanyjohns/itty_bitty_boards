json.extract! order_item, :id, :product_id, :order_id, :unit_price, :quantity, :total_price, :created_at, :updated_at
json.url order_item_url(order_item, format: :json)
