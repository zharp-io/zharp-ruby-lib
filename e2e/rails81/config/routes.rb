Rails.application.routes.draw do
  get "/carts/:id" => "carts#show"
  get "/carts/:id/total" => "carts#total"
  post "/users" => "users#create"
  post "/users/quiet" => "users#create_quietly"
  get "/jobs/fail" => "carts#failing_job"
  get "/pid" => "carts#pid"
end
