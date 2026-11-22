# An HTML page whose template fails: an ActionView::Template::Error from compiled ERB.
class PagesController < ActionController::Base
  def show
    @cart = nil
  end
end
