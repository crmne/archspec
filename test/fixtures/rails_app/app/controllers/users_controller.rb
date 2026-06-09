# frozen_string_literal: true

class UsersController < ApplicationController
  def create
    CreateUser.new.call
    redirect_to '/users'
  end
end
