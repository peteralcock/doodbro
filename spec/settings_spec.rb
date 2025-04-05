require 'spec_helper'
require 'rack/test'
require_relative '../app'

describe 'User Settings' do
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
    db.execute(
      "INSERT INTO user_settings (id, user_id, aws_access_key_id, aws_secret_access_key, aws_region, aws_bucket, created_at) 
       VALUES (1, 1, NULL, NULL, NULL, NULL, datetime('now'))"
    )
    
    db.close
    
    # Mock settings database path for tests
    allow_any_instance_of(Dood).to receive(:settings).and_return(
      double(database_path: 'lawpaw_test.db', 
             upload_folder: 'test_uploads', 
             output_folder: 'test_output',
             public_folder: 'test_public',
             views: 'test_views')
    )
    
    # Login
    post '/login', { username: 'testuser', password: 'password123' }
  end

  describe 'GET /settings' do
    it 'shows settings page when logged in' do
      # Mock methods needed for settings page
      allow_any_instance_of(Dood).to receive(:list_s3_buckets).and_return([])
      allow_any_instance_of(Dood).to receive(:erb).with(:settings).and_return('Settings Page')
      
      get '/settings'
      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to be_empty
    end

    it 'redirects to login when not logged in' do
      get '/logout'  # Logout first
      get '/settings'
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/login')
    end
  end

  describe 'POST /settings/update' do
    it 'updates user settings' do
      post '/settings/update', { 
        aws_access_key_id: 'test_key',
        aws_secret_access_key: 'test_secret',
        aws_region: 'us-west-2',
        aws_bucket: 'test-bucket',
        dropbox_token: 'test_dropbox',
        google_credentials: 'test_google',
        github_token: 'test_github'
      }
      
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/settings')
      
      # Verify settings were updated in database
      db = SQLite3::Database.new('lawpaw_test.db')
      settings = db.execute("SELECT * FROM user_settings WHERE user_id = 1").first
      db.close
      
      expect(settings[2]).to eq('test_key')  # aws_access_key_id
      expect(settings[3]).to eq('test_secret')  # aws_secret_access_key
      expect(settings[4]).to eq('us-west-2')  # aws_region
      expect(settings[5]).to eq('test-bucket')  # aws_bucket
      expect(settings[6]).to eq('test_dropbox')  # dropbox_token
      expect(settings[7]).to eq('test_google')  # google_credentials
      expect(settings[8]).to eq('test_github')  # github_token
    end

    it 'redirects to login when not logged in' do
      get '/logout'  # Logout first
      post '/settings/update', { aws_access_key_id: 'test_key' }
      expect(last_response.status).to eq(302)
      expect(last_response.location).to include('/login')
    end
  end

  describe 'S3 Client Integration' do
    it 'initializes S3 client with user settings' do
      # Mock AWS S3 client
      s3_client_double = double('Aws::S3::Client')
      allow(Aws::S3::Client).to receive(:new).and_return(s3_client_double)
      
      # Update settings
      db = SQLite3::Database.new('lawpaw_test.db')
      db.execute(
        "UPDATE user_settings SET 
         aws_access_key_id = 'test_key',
         aws_secret_access_key = 'test_secret',
         aws_region = 'us-west-2'
         WHERE user_id = 1"
      )
      db.close
      
      # Call initialize_s3_client
      s3_client = app.new.send(:initialize_s3_client, 1)
      
      # Verify S3 client was initialized with correct parameters
      expect(Aws::S3::Client).to have_received(:new).with(
        access_key_id: 'test_key',
        secret_access_key: 'test_secret',
        region: 'us-west-2'
      )
      
      expect(s3_client).to eq(s3_client_double)
    end

    it 'returns nil for S3 client when credentials are missing' do
      s3_client = app.new.send(:initialize_s3_client, 1)
      expect(s3_client).to be_nil
    end
  end

  describe 'S3 Bucket Operations' do
    before(:each) do
      # Update settings with AWS credentials
      db = SQLite3::Database.new('lawpaw_test.db')
      db.execute(
        "UPDATE user_settings SET 
         aws_access_key_id = 'test_key',
         aws_secret_access_key = 'test_secret',
         aws_region = 'us-west-2',
         aws_bucket = 'test-bucket'
         WHERE user_id = 1"
      )
      db.close
      
      # Mock AWS S3 client
      @s3_client_double = double('Aws::S3::Client')
      allow(Aws::S3::Client).to receive(:new).and_return(@s3_client_double)
    end
    
    it 'lists S3 buckets' do
      # Mock bucket response
      bucket1 = double(name: 'bucket1')
      bucket2 = double(name: 'bucket2')
      buckets_response = double(buckets: [bucket1, bucket2])
      allow(@s3_client_double).to receive(:list_buckets).and_return(buckets_response)
      
      # Call list_s3_buckets
      buckets = app.new.send(:list_s3_buckets, 1)
      
      # Verify buckets were returned
      expect(buckets).to eq(['bucket1', 'bucket2'])
    end
    
    it 'lists S3 objects' do
      # Mock objects response
      object1 = double(key: 'file1.pdf', size: 1024, last_modified: Time.now, storage_class: 'STANDARD')
      object2 = double(key: 'file2.pdf', size: 2048, last_modified: Time.now, storage_class: 'STANDARD')
      objects_response = double(contents: [object1, object2])
      allow(@s3_client_double).to receive(:list_objects_v2).with(bucket: 'test-bucket', prefix: '').and_return(objects_response)
      
      # Call list_s3_objects
      objects = app.new.send(:list_s3_objects, 1, 'test-bucket')
      
      # Verify objects were returned
      expect(objects.length).to eq(2)
      expect(objects[0][:key]).to eq('file1.pdf')
      expect(objects[1][:key]).to eq('file2.pdf')
    end
    
    it 'downloads S3 object' do
      # Mock get_object
      allow(@s3_client_double).to receive(:get_object).and_return(true)
      
      # Call download_s3_object
      result = app.new.send(:download_s3_object, 1, 'test-bucket', 'file1.pdf', 'test_path')
      
      # Verify object was downloaded
      expect(result).to eq(true)
      expect(@s3_client_double).to have_received(:get_object).with(
        response_target: 'test_path',
        bucket: 'test-bucket',
        key: 'file1.pdf'
      )
    end
  end
end
