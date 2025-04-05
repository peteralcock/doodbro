require 'spec_helper'
require 'rack/test'
require 'bcrypt'
require_relative '../app'

describe 'User Authentication' do
  include Rack::Test::Methods

  def app
    Dood
  end

  before(:each) do
    # Set up test database
    db = SQLite3::Database.new('lawpaw_test.db')
    
    # Clear tables
    db.execute("DELETE FROM users")
    db.execute("DELETE FROM user_settings")
    
    # Create test user
    password_hash = BCrypt::Password.create('password123')
    db.execute(
      "INSERT INTO users (id, username, email, password_hash, created_at) VALUES (1, 'testuser', 'test@example.com', ?, datetime('now'))",
      password_hash
    )
    
    # Create user settings
    db.execute("INSERT INTO user_settings (user_id, created_at) VALUES (1, datetime('now'))")
    
    db.close
    
    # Mock settings database path for tests
    allow_any_instance_of(Dood).to receive(:settings).and_return(
      double(database_path: 'lawpaw_test.db', 
             upload_folder: 'test_uploads', 
             output_folder: 'test_output',
             public_folder: 'test_public',
             views: 'test_views')
    )
  end

  describe 'GET /' do
    it 'redirects to dashboard when logged in' do
      post '/login', { username: 'testuser', password: 'password123' }
      get '/'
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/dashboard')
    end

    it 'shows landing page when not logged in' do
      get '/'
      expect(last_response.status).to eq(200)
      allow_any_instance_of(Dood).to receive(:erb).with(:landing).and_return('Landing Page')
      expect(last_response.body).not_to be_empty
    end
  end

  describe 'GET /login' do
    it 'shows login page when not logged in' do
      get '/login'
      expect(last_response.status).to eq(200)
      allow_any_instance_of(Dood).to receive(:erb).with(:login).and_return('Login Page')
      expect(last_response.body).not_to be_empty
    end

    it 'redirects to dashboard when already logged in' do
      post '/login', { username: 'testuser', password: 'password123' }
      get '/login'
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/dashboard')
    end
  end

  describe 'POST /login' do
    it 'logs in with correct credentials' do
      post '/login', { username: 'testuser', password: 'password123' }
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/dashboard')
      expect(rack_mock_session.cookie_jar['rack.session']).not_to be_nil
    end

    it 'fails with incorrect password' do
      post '/login', { username: 'testuser', password: 'wrongpassword' }
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/login')
    end

    it 'fails with non-existent user' do
      post '/login', { username: 'nonexistentuser', password: 'password123' }
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/login')
    end
  end

  describe 'GET /register' do
    it 'shows registration page when not logged in' do
      get '/register'
      expect(last_response.status).to eq(200)
      allow_any_instance_of(Dood).to receive(:erb).with(:register).and_return('Register Page')
      expect(last_response.body).not_to be_empty
    end

    it 'redirects to dashboard when already logged in' do
      post '/login', { username: 'testuser', password: 'password123' }
      get '/register'
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/dashboard')
    end
  end

  describe 'POST /register' do
    it 'creates a new user with valid information' do
      post '/register', { 
        username: 'newuser', 
        email: 'new@example.com', 
        password: 'newpassword', 
        confirm_password: 'newpassword' 
      }
      
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/dashboard')
      
      # Verify user was created in database
      db = SQLite3::Database.new('lawpaw_test.db')
      user = db.execute("SELECT * FROM users WHERE username = 'newuser'").first
      db.close
      
      expect(user).not_to be_nil
    end

    it 'fails when passwords do not match' do
      post '/register', { 
        username: 'newuser', 
        email: 'new@example.com', 
        password: 'password1', 
        confirm_password: 'password2' 
      }
      
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/register')
    end

    it 'fails when username already exists' do
      post '/register', { 
        username: 'testuser', 
        email: 'new@example.com', 
        password: 'newpassword', 
        confirm_password: 'newpassword' 
      }
      
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/register')
    end

    it 'fails when email already exists' do
      post '/register', { 
        username: 'newuser', 
        email: 'test@example.com', 
        password: 'newpassword', 
        confirm_password: 'newpassword' 
      }
      
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/register')
    end
  end

  describe 'GET /logout' do
    it 'logs the user out' do
      post '/login', { username: 'testuser', password: 'password123' }
      get '/logout'
      
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/')
      
      # Session should be cleared
      get '/dashboard'
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/login')
    end
  end

  describe 'GET /dashboard' do
    it 'redirects to login when not logged in' do
      get '/dashboard'
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/login')
    end

    it 'shows dashboard when logged in' do
      post '/login', { username: 'testuser', password: 'password123' }
      
      # Mock methods needed for dashboard
      allow_any_instance_of(Dood).to receive(:get_user_projects).and_return([])
      allow_any_instance_of(Dood).to receive(:get_recent_documents).and_return([])
      allow_any_instance_of(Dood).to receive(:erb).with(:dashboard).and_return('Dashboard Page')
      
      get '/dashboard'
      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to be_empty
    end
  end
end
