class UsersController < ApplicationController
  def create
    CreateUser.new.call
    redirect_to "/users"
  end
end
