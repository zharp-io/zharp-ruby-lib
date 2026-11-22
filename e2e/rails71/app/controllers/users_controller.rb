class UsersController < ApplicationController
  # A unique violation that escapes: one error, with the query on it.
  def create
    User.create!(email: params[:email])
    render json: { ok: true }
  end

  # The same failure, rescued: one handled error, still with the query.
  def create_quietly
    User.create!(email: params[:email])
    render json: { ok: true }
  rescue ActiveRecord::RecordNotUnique
    render json: { duplicate: true }, status: :conflict
  end
end
