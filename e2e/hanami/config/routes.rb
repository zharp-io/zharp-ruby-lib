module Shop
  class Routes < Hanami::Routes
    get "/carts/:id", to: "carts.show"
    get "/carts/:id/total", to: "carts.total"
  end
end
