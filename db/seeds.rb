# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end
# ProductCategory.delete_all
tokens = ProductCategory.find_or_create_by name: "tokens"
# ebikes = ProductCategory.create! name: "e-bikes"
# ProductCategory.create! name: "kids bikes & accessories"
# ProductCategory.create! name: "parts"
# ProductCategory.create! name: "bikes accessories"
# ProductCategory.create! name: "clothing & shoes"

# Product.delete_all
Product.find_or_create_by name: "5 tokens", price: 1, coin_value: 5, active: true, product_category: tokens
# Product.find_or_create_by name: "100 tokens", price: 10, coin_value: 100, active: true, product_category: tokens
# Product.find_or_create_by name: "200 tokens", price: 15, coin_value: 200, active: true, product_category: tokens
# Product.find_or_create_by name: "500 tokens", price: 20, coin_value: 500, active: true, product_category: tokens
