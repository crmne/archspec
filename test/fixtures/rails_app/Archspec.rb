# frozen_string_literal: true

architecture :rails
todo 'archspec_todo.yml'

component :views, in: 'app/views/**/*.erb'
component :models, in: 'app/models/**/*.rb'
views.cannot_use :models

component :commands, in: 'app/commands/**/*.rb'
commands.must_implement :call
commands.cannot_call :render, :redirect_to, :params, :session

no_cycles
