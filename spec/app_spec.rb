require 'spec_helper'
require 'rack/test'
require_relative '../app'

describe 'Dood' do
  include Rack::Test::Methods

  def app
    Dood
  end

  it 'should return hello world' do
    get '/'
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)['message']).to eq('Hello, world!')
  end

  it 'should return health status OK' do
    get '/health'
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)['status']).to eq('OK')
  end
end
