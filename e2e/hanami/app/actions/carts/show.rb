module Shop
  module Actions
    module Carts
      class Show < Hanami::Action
        def handle(request, response)
          response.format = :json
          response.body = %({"cart":"#{request.params[:id]}","pid":#{Process.pid}})
        end
      end
    end
  end
end
