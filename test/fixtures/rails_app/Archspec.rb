# frozen_string_literal: true

architecture :rails
baseline '.archspec_todo.yml'

component :commands, in: 'app/commands/**/*.rb'
commands.must_implement :call
commands.cannot_call :render, :redirect_to, :params, :session

no_cycles!
verify_zeitwerk_names!
