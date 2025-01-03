# spec/spec_helper.rb

require 'rack/test'
require 'rspec'

# Load the Sinatra application
ENV['RACK_ENV'] = 'test'

require File.expand_path('../app', __dir__)

RSpec.configure do |config|
  # Include Rack::Test helpers for HTTP testing
  config.include Rack::Test::Methods

  # Define the app for Rack::Test
  def app
    MyApp
  end

  # Enable color in the output
  config.color = true

  # Use documentation format for output
  config.formatter = :documentation

  # Run tests in a random order to surface order dependencies
  config.order = :random

  # Allow focusing on specific tests
  config.filter_run_when_matching :focus

  # Clean up after tests if needed
  config.after(:suite) do
    # Cleanup logic if necessary (e.g., clearing test databases)
  end
end
