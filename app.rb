require 'sinatra/base'
require 'json'
require 'fileutils'
require 'tempfile'
require 'open3'
require 'csv'
require 'sqlite3'
require 'date'

class Dood < Sinatra::Base
  # Configuration
  configure do
    set :upload_folder, File.join(Dir.pwd, 'temp_uploads')
    set :output_folder, File.join(Dir.pwd, 'processed_files')
    set :database_path, File.join(Dir.pwd, 'lawpaw.db')
    enable :sessions
    
    # Ensure directories exist
    FileUtils.mkdir_p(settings.upload_folder)
    FileUtils.mkdir_p(settings.output_folder)
    
    # Initialize database
    init_db
  end
  
  # Database initialization
  def self.init_db
    db = SQLite3::Database.new(settings.database_path)
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS legal_documents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
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
        process_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    SQL
    db.close
  end
  
  # Original routes
  get '/' do
    content_type :json
    { message: 'sup?' }.to_json
  end

  get '/health' do
    content_type :json
    { status: 'im good.' }.to_json
  end
  
  # Legal document processor routes
  get '/legal' do
    erb :index
  end
  
  post '/process' do
    content_type :json
    
    # Get parameters from request
    input_folder = params[:input_folder]
    output_folder = params[:output_folder]
    keyword = params[:keyword]
    
    # Validate parameters
    unless input_folder && output_folder && keyword
      return { error: "Missing required parameters" }.to_json
    end
    
    # Validate folders exist
    unless Dir.exist?(input_folder)
      return { error: "Input folder does not exist" }.to_json
    end
    
    # Create output folder if needed
    begin
      FileUtils.mkdir_p(output_folder) unless Dir.exist?(output_folder)
    rescue => e
      return { error: "Could not create output folder: #{e.message}" }.to_json
    end
    
    # Find PDFs containing keyword using bulk_extractor
    matching_files = run_bulk_extractor(input_folder, keyword)
    
    if matching_files.empty?
      return { message: "No matching files found" }.to_json
    end
    
    # Process each file
    results = []
    matching_files.each do |file_path|
      begin
        # OCR first page top half
        ocr_text = ocr_first_page(file_path)
        
        # Analyze with OpenAI
        doc_info = analyze_document_with_openai(ocr_text)
        
        # Organize file
        new_file_path = organize_files(doc_info, file_path, output_folder)
        
        # Save to database
        save_to_database(doc_info, file_path, new_file_path)
        
        # Add to results
        result = {
          filename: File.basename(file_path),
          original_path: file_path,
          new_path: new_file_path
        }.merge(doc_info)
        
        results << result
      rescue => e
        puts "Error processing #{file_path}: #{e.message}"
        next
      end
    end
    
    # Save results to CSV
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    csv_path = File.join(output_folder, "legal_documents_#{timestamp}.csv")
    save_to_csv(results, csv_path)
    
    {
      message: "Processed #{results.length} files",
      results: results,
      csv_path: csv_path
    }.to_json
  end
  
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
      system("convert -density 300 \"#{temp_first
