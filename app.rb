require 'sinatra/base'
require 'sinatra/flash'
require 'json'
require 'fileutils'
require 'tempfile'
require 'open3'
require 'csv'
require 'sqlite3'
require 'date'
require 'openai'
require 'aws-sdk-s3'
require 'bcrypt'
require 'dropbox_api'
require 'google/apis/drive_v3'
require 'googleauth'
require 'googleauth/stores/file_token_store'
require 'octokit'

class Dood < Sinatra::Base
  # Configuration
  configure do
    set :upload_folder, File.join(Dir.pwd, 'temp_uploads')
    set :output_folder, File.join(Dir.pwd, 'processed_files')
    set :database_path, File.join(Dir.pwd, 'lawpaw.db')
    set :public_folder, File.join(Dir.pwd, 'public')
    set :views, File.join(Dir.pwd, 'views')
    
    enable :sessions
    set :session_secret, ENV.fetch('SESSION_SECRET') { SecureRandom.hex(64) }
    register Sinatra::Flash
    
    # Ensure directories exist
    FileUtils.mkdir_p(settings.upload_folder)
    FileUtils.mkdir_p(settings.output_folder)
    FileUtils.mkdir_p(File.join(settings.public_folder, 'assets'))
    FileUtils.mkdir_p(File.join(Dir.pwd, 'views'))
    
    # Initialize database
    init_db
    
    # Configure OpenAI client
    set :openai_client, OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])
    
    # Initialize AWS S3 client
    set :s3_client, nil
  end
  
  # Database initialization
  def self.init_db
    db = SQLite3::Database.new(settings.database_path)
    
    # Users table
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        email TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        last_login TIMESTAMP
      )
    SQL
    
    # User settings table
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS user_settings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        aws_access_key_id TEXT,
        aws_secret_access_key TEXT,
        aws_region TEXT,
        aws_bucket TEXT,
        dropbox_token TEXT,
        google_credentials TEXT,
        github_token TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP,
        FOREIGN KEY (user_id) REFERENCES users(id)
      )
    SQL
    
    # Legal documents table
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS legal_documents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER,
        filename TEXT NOT NULL,
        original_path TEXT,
        new_path TEXT,
        document_type TEXT,
        filing_date TEXT,
        moving_party TEXT,
        court TEXT,
        judge TEXT,
        docket_number TEXT,
        summary TEXT,
        tags TEXT,
        source_type TEXT,
        source_location TEXT,
        process_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (user_id) REFERENCES users(id)
      )
    SQL
    
    # Storage sources table
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS storage_sources (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        path TEXT,
        credentials_id INTEGER,
        active BOOLEAN DEFAULT 1,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP,
        FOREIGN KEY (user_id) REFERENCES users(id),
        FOREIGN KEY (credentials_id) REFERENCES user_settings(id)
      )
    SQL
    
    # Projects table for organizing document sets
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS projects (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        description TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP,
        FOREIGN KEY (user_id) REFERENCES users(id)
      )
    SQL
    
    # Project documents linking table
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS project_documents (
        project_id INTEGER NOT NULL,
        document_id INTEGER NOT NULL,
        added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (project_id, document_id),
        FOREIGN KEY (project_id) REFERENCES projects(id),
        FOREIGN KEY (document_id) REFERENCES legal_documents(id)
      )
    SQL
    
    db.close
  end
  
  # Helper methods for authentication
  def logged_in?
    !session[:user_id].nil?
  end
  
  def current_user
    return nil unless logged_in?
    db = SQLite3::Database.new(settings.database_path)
    db.results_as_hash = true
    user = db.execute("SELECT * FROM users WHERE id = ?", session[:user_id]).first
    db.close
    user
  end
  
  def authenticate_user
    redirect '/login' unless logged_in?
  end
  
  def get_user_settings(user_id)
    db = SQLite3::Database.new(settings.database_path)
    db.results_as_hash = true
    settings = db.execute("SELECT * FROM user_settings WHERE user_id = ?", user_id).first
    db.close
    settings || {}
  end
  
  def initialize_s3_client(user_id)
    settings = get_user_settings(user_id)
    return nil unless settings['aws_access_key_id'] && settings['aws_secret_access_key']
    
    begin
      Aws::S3::Client.new(
        access_key_id: settings['aws_access_key_id'],
        secret_access_key: settings['aws_secret_access_key'],
        region: settings['aws_region'] || 'us-east-1'
      )
    rescue => e
      puts "Error initializing S3 client: #{e.message}"
      nil
    end
  end
  
  def list_s3_buckets(user_id)
    s3_client = initialize_s3_client(user_id)
    return [] unless s3_client
    
    begin
      response = s3_client.list_buckets
      response.buckets.map(&:name)
    rescue => e
      puts "Error listing S3 buckets: #{e.message}"
      []
    end
  end
  
  def list_s3_objects(user_id, bucket, prefix = '')
    s3_client = initialize_s3_client(user_id)
    return [] unless s3_client
    
    begin
      response = s3_client.list_objects_v2(bucket: bucket, prefix: prefix)
      response.contents.map do |object|
        {
          key: object.key,
          size: object.size,
          last_modified: object.last_modified,
          storage_class: object.storage_class
        }
      end
    rescue => e
      puts "Error listing S3 objects: #{e.message}"
      []
    end
  end
  
  def download_s3_object(user_id, bucket, key, local_path)
    s3_client = initialize_s3_client(user_id)
    return false unless s3_client
    
    begin
      s3_client.get_object(
        response_target: local_path,
        bucket: bucket,
        key: key
      )
      true
    rescue => e
      puts "Error downloading S3 object: #{e.message}"
      false
    end
  end
  
  def list_user_storage_sources(user_id)
    db = SQLite3::Database.new(settings.database_path)
    db.results_as_hash = true
    sources = db.execute("SELECT * FROM storage_sources WHERE user_id = ? AND active = 1", user_id)
    db.close
    sources
  end
  
  def get_user_projects(user_id)
    db = SQLite3::Database.new(settings.database_path)
    db.results_as_hash = true
    projects = db.execute("SELECT * FROM projects WHERE user_id = ? ORDER BY updated_at DESC", user_id)
    db.close
    projects
  end
  
  def get_project_documents(project_id)
    db = SQLite3::Database.new(settings.database_path)
    db.results_as_hash = true
    documents = db.execute(
      "SELECT ld.* FROM legal_documents ld 
       JOIN project_documents pd ON ld.id = pd.document_id 
       WHERE pd.project_id = ?", 
      project_id
    )
    db.close
    documents
  end

  # Original API routes
  get '/api' do
    content_type :json
    { message: 'sup?' }.to_json
  end

  get '/api/health' do
    content_type :json
    { status: 'im good.' }.to_json
  end
  
  # Authentication routes
  get '/' do
    if logged_in?
      redirect '/dashboard'
    else
      erb :landing
    end
  end
  
  get '/login' do
    redirect '/dashboard' if logged_in?
    erb :login
  end
  
  post '/login' do
    username = params[:username]
    password = params[:password]
    
    db = SQLite3::Database.new(settings.database_path)
    db.results_as_hash = true
    user = db.execute("SELECT * FROM users WHERE username = ? OR email = ?", username, username).first
    db.close
    
    if user && BCrypt::Password.new(user['password_hash']) == password
      session[:user_id] = user['id']
      
      # Update last login
      db = SQLite3::Database.new(settings.database_path)
      db.execute("UPDATE users SET last_login = datetime('now') WHERE id = ?", user['id'])
      db.close
      
      redirect '/dashboard'
    else
      flash[:error] = "Invalid username or password"
      redirect '/login'
    end
  end
  
  get '/register' do
    redirect '/dashboard' if logged_in?
    erb :register
  end
  
  post '/register' do
    username = params[:username]
    email = params[:email]
    password = params[:password]
    confirm_password = params[:confirm_password]
    
    if password != confirm_password
      flash[:error] = "Passwords do not match"
      redirect '/register'
    end
    
    db = SQLite3::Database.new(settings.database_path)
    
    # Check if username or email already exists
    existing = db.execute("SELECT * FROM users WHERE username = ? OR email = ?", username, email)
    
    if !existing.empty?
      db.close
      flash[:error] = "Username or email already exists"
      redirect '/register'
    end
    
    # Create new user
    password_hash = BCrypt::Password.create(password)
    db.execute(
      "INSERT INTO users (username, email, password_hash, created_at) VALUES (?, ?, ?, datetime('now'))",
      username, email, password_hash
    )
    
    # Get the new user ID
    user_id = db.last_insert_row_id
    
    # Create default user settings
    db.execute("INSERT INTO user_settings (user_id, created_at) VALUES (?, datetime('now'))", user_id)
    
    db.close
    
    session[:user_id] = user_id
    redirect '/dashboard'
  end
  
  get '/logout' do
    session.clear
    redirect '/'
  end
  
  # Dashboard and main application routes
  get '/dashboard' do
    authenticate_user
    @user = current_user
    @projects = get_user_projects(@user['id'])
    @recent_documents = get_recent_documents(@user['id'])
    erb :dashboard
  end
  
  get '/settings' do
    authenticate_user
    @user = current_user
    @settings = get_user_settings(@user['id'])
    @s3_buckets = list_s3_buckets(@user['id'])
    erb :settings
  end
  
  post '/settings/update' do
    authenticate_user
    user_id = current_user['id']
    
    # Update user settings
    db = SQLite3::Database.new(settings.database_path)
    db.execute(
      "UPDATE user_settings SET 
       aws_access_key_id = ?, aws_secret_access_key = ?, aws_region = ?, aws_bucket = ?,
       dropbox_token = ?, google_credentials = ?, github_token = ?,
       updated_at = datetime('now')
       WHERE user_id = ?",
      params[:aws_access_key_id], params[:aws_secret_access_key], params[:aws_region], params[:aws_bucket],
      params[:dropbox_token], params[:google_credentials], params[:github_token],
      user_id
    )
    db.close
    
    flash[:success] = "Settings updated successfully"
    redirect '/settings'
  end
  
  get '/storage' do
    authenticate_user
    @user = current_user
    @storage_sources = list_user_storage_sources(@user['id'])
    @s3_buckets = list_s3_buckets(@user['id'])
    erb :storage
  end
  
  post '/storage/add' do
    authenticate_user
    user_id = current_user['id']
    
    db = SQLite3::Database.new(settings.database_path)
    db.execute(
      "INSERT INTO storage_sources (user_id, name, type, path, credentials_id, created_at, updated_at) 
       VALUES (?, ?, ?, ?, ?, datetime('now'), datetime('now'))",
      user_id, params[:name], params[:type], params[:path], params[:credentials_id]
    )
    db.close
    
    flash[:success] = "Storage source added successfully"
    redirect '/storage'
  end
  
  get '/storage/:id/browse' do
    authenticate_user
    user_id = current_user['id']
    
    db = SQLite3::Database.new(settings.database_path)
    db.results_as_hash = true
    storage_source = db.execute("SELECT * FROM storage_sources WHERE id = ? AND user_id = ?", params[:id], user_id).first
    db.close
    
    if storage_source.nil?
      flash[:error] = "Storage source not found"
      redirect '/storage'
    end
    
    @source = storage_source
    
    case storage_source['type']
    when 's3'
      settings = get_user_settings(user_id)
      @files = list_s3_objects(user_id, settings['aws_bucket'], params[:prefix])
    when 'local'
      path = storage_source['path']
      @files = Dir.glob(File.join(path, '*')).map do |file|
        {
          key: file.sub("#{path}/", ''),
          size: File.size(file),
          last_modified: File.mtime(file),
          storage_class: 'local'
        }
      end
    else
      @files = []
    end
    
    erb :browse_storage
  end
  
  # Legal document processor routes
  get '/documents' do
    authenticate_user
    @user = current_user
    @documents = get_user_documents(@user['id'])
    erb :documents
  end
  
  get '/documents/:id' do
    authenticate_user
    @user = current_user
    
    db = SQLite3::Database.new(settings.database_path)
    db.results_as_hash = true
    @document = db.execute("SELECT * FROM legal_documents WHERE id = ? AND user_id = ?", params[:id], @user['id']).first
    db.close
    
    if @document.nil?
      flash[:error] = "Document not found"
      redirect '/documents'
    end
    
    erb :document_details
  end
  
  get '/legal' do
    authenticate_user
    @user = current_user
    @storage_sources = list_user_storage_sources(@user['id'])
    @s3_buckets = list_s3_buckets(@user['id'])
    erb :legal_processor
  end
  
  # Helper method to get recent documents
  def get_recent_documents(user_id, limit = 10)
    db = SQLite3::Database.new(settings.database_path)
    db.results_as_hash = true
    documents = db.execute(
      "SELECT * FROM legal_documents WHERE user_id = ? ORDER BY process_date DESC LIMIT ?", 
      user_id, limit
    )
    db.close
    documents
  end
  
  def get_user_documents(user_id, filter = {})
    db = SQLite3::Database.new(settings.database_path)
    db.results_as_hash = true
    
    query = "SELECT * FROM legal_documents WHERE user_id = ?"
    params = [user_id]
    
    if filter[:document_type]
      query += " AND document_type = ?"
      params << filter[:document_type]
    end
    
    if filter[:docket_number]
      query += " AND docket_number LIKE ?"
      params << "%#{filter[:docket_number]}%"
    end
    
    if filter[:search]
      query += " AND (summary LIKE ? OR tags LIKE ? OR moving_party LIKE ? OR court LIKE ?)"
      params += ["%#{filter[:search]}%", "%#{filter[:search]}%", "%#{filter[:search]}%", "%#{filter[:search]}%"]
    end
    
    query += " ORDER BY process_date DESC"
    
    if filter[:limit]
      query += " LIMIT ?"
      params << filter[:limit]
    end
    
    documents = db.execute(query, params)
    db.close
    documents
  end
  
  # Process documents from various sources
  post '/process' do
    authenticate_user
    user_id = current_user['id']
    
    content_type :json
    
    # Get parameters from request
    source_type = params[:source_type]
    keyword = params[:keyword]
    
    # Initialize temp directories
    temp_input_dir = Dir.mktmpdir
    output_folder = params[:output_folder] || File.join(settings.output_folder, "user_#{user_id}", Time.now.strftime("%Y%m%d_%H%M%S"))
    
    # Create output folder
    begin
      FileUtils.mkdir_p(output_folder)
    rescue => e
      return { error: "Could not create output folder: #{e.message}" }.to_json
    end
    
    # Process different source types
    case source_type
    when 'local'
      input_folder = params[:input_folder]
      
      # Validate input folder exists
      unless Dir.exist?(input_folder)
        return { error: "Input folder does not exist" }.to_json
      end
      
      # Find PDFs containing keyword using bulk_extractor
      matching_files = run_bulk_extractor(input_folder, keyword)
      
    when 's3'
      bucket = params[:bucket]
      prefix = params[:prefix] || ''
      
      # Initialize S3 client
      s3_client = initialize_s3_client(user_id)
      unless s3_client
        return { error: "Could not initialize S3 client. Please check your AWS credentials." }.to_json
      end
      
      # List objects in the bucket with the given prefix
      begin
        objects =
  
  get '/download-csv/:filename' do
    filename = params[:filename]
    send_file filename, disposition: 'attachment'
  end
  
  # Helper methods
  private
  
  def run_bulk_extractor(folder_path, keyword)
    temp_output_dir = Dir.mktmpdir
    matching_files = []
    
    begin
      # Run bulk_extractor command
      cmd = [
        'bulk_extractor',
        '-e', 'wordlist',
        '-S', "wordlist_keylist=#{keyword}",
        '-o', temp_output_dir,
        folder_path
      ]
      
      stdout, stderr, status = Open3.capture3(*cmd)
      
      if status.success?
        # Parse output to get file paths with matches
        wordlist_path = File.join(temp_output_dir, 'wordlist.txt')
        if File.exist?(wordlist_path)
          File.readlines(wordlist_path).each do |line|
            if line.downcase.include?(keyword.downcase)
              parts = line.strip.split("\t")
              if parts.length >= 2 && parts[1].end_with?('.pdf')
                file_path = parts[1].sub('file://', '')
                matching_files << file_path
              end
            end
          end
        end
      else
        puts "Error running bulk_extractor: #{stderr}"
      end
    rescue => e
      puts "Exception running bulk_extractor: #{e.message}"
    ensure
      # Clean up
      FileUtils.rm_rf(temp_output_dir)
    end
    
    matching_files.uniq
  end
  
  def ocr_first_page(pdf_path)
    begin
      # Extract first page using pdftk
      temp_first_page = Tempfile.new(['first_page', '.pdf'])
      system("pdftk \"#{pdf_path}\" cat 1 output \"#{temp_first_page.path}\"")
      
      # Convert to image using ImageMagick
      temp_image = Tempfile.new(['page_image', '.png'])
      system("convert -density 300 \"#{temp_first_page.path}\" -crop 100%x50%+0+0 \"#{temp_image.path}\"")
      
      # OCR using tesseract
      temp_text = Tempfile.new(['ocr_text', '.txt'])
      system("tesseract \"#{temp_image.path}\" \"#{temp_text.path.sub(/\.txt$/, '')}\"")
      
      # Read OCR text
      ocr_text = File.read("#{temp_text.path.sub(/\.txt$/, '')}.txt")
      
      ocr_text
    rescue => e
      puts "Error in OCR process: #{e.message}"
      "Error processing document: #{e.message}"
    ensure
      # Clean up temp files
      [temp_first_page, temp_image, temp_text].each do |file|
        file.close
        file.unlink if File.exist?(file.path)
      end if defined?(temp_first_page) && defined?(temp_image) && defined?(temp_text)
    end
  end
  
  def analyze_document_with_openai(text)
    begin
      # Use the ruby-openai gem to make the API call
      response = settings.openai_client.chat(
        parameters: {
          model: "gpt-4o",
          messages: [
            {
              role: "system",
              content: "You are a legal document analyzer. Extract the following information as structured data: 
              - document_type (be specific: motion, reply, opposition, complaint, answer, notice, memorandum, declaration, 
                affidavit, subpoena, writ, order, judgment, verdict, brief, petition, stipulation, etc.)
              - filing_date (in YYYY-MM-DD format)
              - moving_party (the party filing the document)
              - responding_party (if applicable)
              - court (full court name)
              - jurisdiction (federal, state, county, etc.)
              - judge (full name with title)
              - docket_number (exact format as in document)
              - case_name (parties involved in the case)
              - cause_of_action (for complaints/petitions)
              - relief_sought (what the filing party is asking for)
              - filing_attorney (name and firm)
              - summary (brief 1-2 sentence description)
              - tags (comma-separated keywords related to the document)"
            },
            {
              role: "user",
              content: text
            }
          ],
          response_format: { type: "json_object" }
        }
      )
      
      # Parse the JSON response from the content
      content = response.dig("choices", 0, "message", "content")
      result = JSON.parse(content)
      
      # Set defaults for any missing fields
      default_fields = {
        "document_type" => "unknown",
        "filing_date" => Time.now.strftime("%Y-%m-%d"),
        "moving_party" => "unknown",
        "responding_party" => "",
        "court" => "unknown",
        "jurisdiction" => "",
        "judge" => "unknown",
        "docket_number" => "unknown",
        "case_name" => "",
        "cause_of_action" => "",
        "relief_sought" => "",
        "filing_attorney" => "",
        "summary" => "No summary available",
        "tags" => ""
      }
      
      default_fields.merge(result)
    rescue => e
      puts "Error with OpenAI API: #{e.message}"
      {
        "error" => e.message,
        "document_type" => "unknown",
        "filing_date" => Time.now.strftime("%Y-%m-%d"),
        "moving_party" => "unknown",
        "responding_party" => "",
        "court" => "unknown",
        "jurisdiction" => "",
        "judge" => "unknown",
        "docket_number" => "unknown",
        "case_name" => "",
        "cause_of_action" => "",
        "relief_sought" => "",
        "filing_attorney" => "",
        "summary" => "Error analyzing document",
        "tags" => ""
      }
    end
  end
  
  def generate_filename(doc_info)
    begin
      # Format: PL_PartyName_DocumentType_Descriptor_Date
      party = doc_info['moving_party'] || 'Unknown'
      party = party.gsub(/[^\w]/, '').capitalize
      
      doc_type = case (doc_info['document_type'] || '').downcase
                 when 'motion'
                   'MOT'
                 when 'opposition'
                   'OPP'
                 when 'reply'
                   'REP'
                 else
                   'DOC'
                 end
      
      # Extract date in MM-DD-YYYY format
      date_str = doc_info['filing_date'] || ''
      formatted_date = if date_str.match?(/\d{4}-\d{2}-\d{2}/)
                        Date.parse(date_str).strftime('%m-%d-%Y')
                      else
                        date_str.gsub('/', '-').gsub('.', '-')
                      end
      
      # Create descriptor from first 3 words of summary
      summary = doc_info['summary'] || ''
      summary_words = summary.scan(/\w+/)[0..2]
      descriptor = summary_words.empty? ? 'GENERAL' : summary_words.join('_').upcase
      
      filename = "PL_#{party}_#{doc_type}_#{descriptor}_#{formatted_date}.pdf"
      
      # Sanitize filename
      filename.gsub(/[^0-9A-Za-z._-]/, '_')
    rescue => e
      puts "Error generating filename: #{e.message}"
      "PL_Document_#{Time.now.strftime('%m-%d-%Y')}.pdf"
    end
  end
  
  def save_to_database(doc_info, original_path, new_path)
    begin
      db = SQLite3::Database.new(settings.database_path)
      
      db.execute(
        "INSERT INTO legal_documents 
        (filename, original_path, new_path, document_type, filing_date, moving_party, court, judge, docket_number, summary)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [
          File.basename(new_path),
          original_path,
          new_path,
          doc_info['document_type'],
          doc_info['filing_date'],
          doc_info['moving_party'],
          doc_info['court'],
          doc_info['judge'],
          doc_info['docket_number'],
          doc_info['summary']
        ]
      )
      
      db.close
      true
    rescue => e
      puts "Database error: #{e.message}"
      false
    end
  end
  
  def save_to_csv(results, output_path)
    begin
      CSV.open(output_path, 'w') do |csv|
        # Header row
        csv << [
          'filename', 'original_path', 'new_path', 'document_type',
          'filing_date', 'moving_party', 'court', 'judge',
          'docket_number', 'summary'
        ]
        
        # Data rows
        results.each do |result|
          csv << [
            result[:filename], result[:original_path], result[:new_path],
            result[:document_type], result[:filing_date], result[:moving_party],
            result[:court], result[:judge], result[:docket_number], result[:summary]
          ]
        end
      end
      
      true
    rescue => e
      puts "CSV error: #{e.message}"
      false
    end
  end
  
  def organize_files(doc_info, original_file, output_base_dir)
    begin
      # Extract information
      docket = doc_info['docket_number'] || 'Unknown_Docket'
      party = doc_info['moving_party'] || 'Unknown_Party'
      doc_type = doc_info['document_type'] || 'Unknown_Type'
      date_str = doc_info['filing_date'] || Time.now.strftime('%Y-%m-%d')
      
      # Clean up folder names
      docket = docket.gsub(/[^0-9A-Za-z._-]/, '_')
      party = party.gsub(/[^0-9A-Za-z._-]/, '_')
      doc_type = doc_type.gsub(/[^0-9A-Za-z._-]/, '_')
      date_str = date_str.gsub(/[^0-9A-Za-z._-]/, '_')
      
      # Create directory structure
      output_dir = File.join(output_base_dir, docket, party, doc_type, date_str)
      FileUtils.mkdir_p(output_dir)
      
      # Generate filename and copy file
      new_filename = generate_filename(doc_info)
      output_path = File.join(output_dir, new_filename)
      
      FileUtils.cp(original_file, output_path)
      
      output_path
    rescue => e
      puts "File organization error: #{e.message}"
      nil
    end
  end
  
  helpers do
    def send_file(path, options={})
      unless File.file?(path) && File.readable?(path)
        halt 404
      end
      
      filename = File.basename(path)
      attachment options[:disposition] == 'attachment' ? filename : nil
      
      if options[:type]
        content_type options[:type]
      else
        content_type File.extname(filename), charset: options[:charset] || 'utf-8'
      end
      
      File.open(path, 'rb') do |file|
        file.read
      end
    end
  end
  
  # Views
  template :index do
    <<-HTML
<!DOCTYPE html>
<html>
<head>
    <title>Legal Document Processor</title>
    <script src="https://cdn.jsdelivr.net/npm/alpinejs@3.12.0/dist/cdn.min.js" defer></script>
    <link href="https://cdn.jsdelivr.net/npm/tailwindcss@2.2.19/dist/tailwind.min.css" rel="stylesheet">
</head>
<body class="bg-gray-100 min-h-screen">
    <div class="container mx-auto px-4 py-8" x-data="{
        inputFolder: '',
        outputFolder: '',
        keyword: '',
        processing: false,
        results: null,
        error: null,
        selectInputFolder() {
            // This would need system file dialog integration
            // For web demo, we'll just use a text input
            this.inputFolder = prompt('Enter input folder path:', '/path/to/input');
        },
        selectOutputFolder() {
            // This would need system file dialog integration
            // For web demo, we'll just use a text input
            this.outputFolder = prompt('Enter output folder path:', '/path/to/output');
        },
        async processFiles() {
            if (!this.inputFolder || !this.outputFolder || !this.keyword) {
                this.error = 'All fields are required';
                return;
            }
            
            this.processing = true;
            this.error = null;
            this.results = null;
            
            try {
                const formData = new FormData();
                formData.append('input_folder', this.inputFolder);
                formData.append('output_folder', this.outputFolder);
                formData.append('keyword', this.keyword);
                
                const response = await fetch('/process', {
                    method: 'POST',
                    body: formData
                });
                
                const data = await response.json();
                
                if (response.ok) {
                    this.results = data;
                } else {
                    this.error = data.error || 'An error occurred';
                }
            } catch (err) {
                this.error = 'Failed to process files: ' + err.message;
            } finally {
                this.processing = false;
            }
        }
    }">
        <h1 class="text-3xl font-bold text-center mb-8">Legal Document Processor</h1>
        
        <div class="bg-white shadow-md rounded-lg p-6 mb-8">
            <div class="mb-4">
                <label class="block text-gray-700 mb-2">Input Folder</label>
                <div class="flex">
                    <input type="text" x-model="inputFolder" class="flex-1 border rounded-l px-4 py-2" readonly>
                    <button @click="selectInputFolder()" class="bg-blue-500 text-white px-4 py-2 rounded-r">Browse</button>
                </div>
            </div>
            
            <div class="mb-4">
                <label class="block text-gray-700 mb-2">Output Folder</label>
                <div class="flex">
                    <input type="text" x-model="outputFolder" class="flex-1 border rounded-l px-4 py-2" readonly>
                    <button @click="selectOutputFolder()" class="bg-blue-500 text-white px-4 py-2 rounded-r">Browse</button>
                </div>
            </div>
            
            <div class="mb-6">
                <label class="block text-gray-700 mb-2">Keyword to Search</label>
                <input type="text" x-model="keyword" class="w-full border rounded px-4 py-2">
            </div>
            
            <button @click="processFiles()" class="w-full bg-green-500 text-white py-2 rounded font-bold" 
                    :disabled="processing" 
                    :class="{'opacity-50 cursor-not-allowed': processing}">
                <span x-show="!processing">Process Files</span>
                <span x-show="processing">Processing... Please wait</span>
            </button>
        </div>
        
        <!-- Error message -->
        <div x-show="error" class="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
            <p x-text="error"></p>
        </div>
        
        <!-- Results -->
        <div x-show="results" class="bg-white shadow-md rounded-lg p-6">
            <h2 class="text-xl font-bold mb-4">Results</h2>
            <p class="mb-4" x-text="`Processed ${results?.results?.length || 0} files`"></p>
            
            <a x-show="results?.csv_path" 
               :href="`/download-csv/${encodeURIComponent(results.csv_path)}`" 
               class="inline-block bg-blue-500 text-white px-4 py-2 rounded mb-6">
                Download CSV Report
            </a>
            
            <div x-show="results?.results?.length > 0" class="overflow-x-auto">
                <table class="min-w-full divide-y divide-gray-200">
                    <thead class="bg-gray-50">
                        <tr>
                            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Filename</th>
                            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Document Type</th>
                            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Filing Date</th>
                            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Moving Party</th>
                            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Court</th>
                            <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Docket #</th>
                        </tr>
                    </thead>
                    <tbody class="bg-white divide-y divide-gray-200">
                        <template x-for="(item, index) in results.results" :key="index">
                            <tr>
                                <td class="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900" x-text="item.filename"></td>
                                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500" x-text="item.document_type"></td>
                                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500" x-text="item.filing_date"></td>
                                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500" x-text="item.moving_party"></td>
                                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500" x-text="item.court"></td>
                                <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500" x-text="item.docket_number"></td>
                            </tr>
                        </template>
                    </tbody>
                </table>
            </div>
        </div>
    </div>
</body>
</html>
    HTML
  end
end

# Run the application if this file is executed directly
if __FILE__ == $0
  Dood.run!
end
