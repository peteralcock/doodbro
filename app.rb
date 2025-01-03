require 'sinatra'
require 'json'
class Dood < Sinatra::Base
  get '/' do
    { message: 'sup?' }.to_json
  end
  
  get '/health' do
    halt 500, { status: 'nah bro' }.to_json
  end

  get '/health' do
    { status: 'im good' }.to_json
  end
end

