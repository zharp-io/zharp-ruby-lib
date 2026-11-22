Rails.application.routes.draw do
  get "/carts/:id" => "carts#show"
  get "/carts/:id/total" => "carts#total"
  get "/pages/:id" => "pages#show"
  post "/users" => "users#create"
  post "/users/quiet" => "users#create_quietly"
end
