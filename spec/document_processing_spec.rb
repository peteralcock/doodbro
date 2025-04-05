require 'spec_helper'
require 'rack/test'
require_relative '../app'

describe 'Document Processing' do
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
    db.execute("DELETE FROM legal_documents")
    db.execute("DELETE FROM storage_sources")
    
    # Create test user
    password_hash = BCrypt::Password.create('password123')
    db.execute(
      "INSERT INTO users (id, username, email, password_hash, created_at) VALUES (1, 'testuser', 'test@example.com', ?, datetime('now'))",
      password_hash
    )
    
    # Create user settings with AWS credentials
    db.execute(
      "INSERT INTO user_settings (id, user_id, aws_access_key_id, aws_secret_access_key, aws_region, aws_bucket, created_at) 
       VALUES (1, 1, 'test_key', 'test_secret', 'us-west-2', 'test-bucket', datetime('now'))"
    )
    
    # Create storage source
    db.execute(
      "INSERT INTO storage_sources (id, user_id, name, type, path, created_at) 
       VALUES (1, 1, 'Test Local', 'local', '/test/path', datetime('now'))"
    )
    
    db.close
    
    # Mock settings
    allow_any_instance_of(Dood).to receive(:settings).and_return(
      double(
        database_path: 'lawpaw_test.db', 
        upload_folder: 'test_uploads', 
        output_folder: 'test_output',
        public_folder: 'test_public',
        views: 'test_views',
        openai_client: double('OpenAI::Client')
      )
    )
    
    # Login
    post '/login', { username: 'testuser', password: 'password123' }
    
    # Create test directories
    FileUtils.mkdir_p('test_uploads')
    FileUtils.mkdir_p('test_output')
  end

  after(:each) do
    # Clean up test directories
    FileUtils.rm_rf('test_uploads')
    FileUtils.rm_rf('test_output')
  end

  describe 'Document Analysis with OpenAI' do
    it 'analyzes document text with OpenAI' do
      # Mock OpenAI client
      openai_response = {
        'choices' => [
          {
            'message' => {
              'content' => '{
                "document_type": "motion",
                "filing_date": "2024-04-01",
                "moving_party": "Test Plaintiff",
                "responding_party": "Test Defendant",
                "court": "Test Court",
                "jurisdiction": "Federal",
                "judge": "Judge Test",
                "docket_number": "CV-2024-1234",
                "case_name": "Test Plaintiff v. Test Defendant",
                "cause_of_action": "Breach of Contract",
                "relief_sought": "Damages",
                "filing_attorney": "Test Attorney",
                "summary": "Motion for summary judgment",
                "tags": "motion,summary,judgment"
              }'
            }
          }
        ]
      }
      
      allow_any_instance_of(OpenAI::Client).to receive(:chat).and_return(openai_response)
      
      # Call analyze_document_with_openai
      result = app.new.send(:analyze_document_with_openai, 'Test document text')
      
      # Verify analysis results
      expect(result['document_type']).to eq('motion')
      expect(result['filing_date']).to eq('2024-04-01')
      expect(result['docket_number']).to eq('CV-2024-1234')
      expect(result['tags']).to eq('motion,summary,judgment')
    end

    it 'handles errors in OpenAI analysis' do
      # Mock OpenAI client to raise error
      allow_any_instance_of(OpenAI::Client).to receive(:chat).and_raise(StandardError.new('API error'))
      
      # Call analyze_document_with_openai
      result = app.new.send(:analyze_document_with_openai, 'Test document text')
      
      # Verify error handling
      expect(result['error']).to include('API error')
      expect(result['document_type']).to eq('unknown')
      expect(result['summary']).to eq('Error analyzing document')
    end
  end

  describe 'Bulk Extractor' do
    it 'finds PDFs containing keywords' do
      # Mock Open3.capture3 for bulk_extractor
      wordlist_content = "test_keyword\tfile:///test/path/file1.pdf\ntest_keyword\tfile:///test/path/file2.pdf"
      allow(Open3).to receive(:capture3) do |*args|
        # Create a mock wordlist.txt file
        FileUtils.mkdir_p(File.join(Dir.mktmpdir, 'wordlist.txt'))
        File.write(File.join(Dir.mktmpdir, 'wordlist.txt'), wordlist_content)
        ['stdout', 'stderr', double('status', success?: true)]
      end
      
      # Mock File.exist? and File.readlines
      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:readlines).and_return(
        ["test_keyword\tfile:///test/path/file1.pdf", "test_keyword\tfile:///test/path/file2.pdf"]
      )
      
      # Call run_bulk_extractor
      result = app.new.send(:run_bulk_extractor, '/test/path', 'test_keyword')
      
      # Verify matching files
      expect(result).to include('/test/path/file1.pdf')
      expect(result).to include('/test/path/file2.pdf')
    end
  end

  describe 'OCR Processing' do
    it 'extracts text from PDF using OCR' do
      # Mock system calls for PDF processing
      allow(app.new).to receive(:system).and_return(true)
      allow(File).to receive(:read).and_return('Extracted OCR text')
      
      # Call ocr_first_page
      result = app.new.send(:ocr_first_page, 'test.pdf')
      
      # Verify OCR text
      expect(result).to eq('Extracted OCR text')
    end
  end

  describe 'File Organization' do
    it 'generates filename based on document info' do
      doc_info = {
        'document_type' => 'motion',
        'filing_date' => '2024-04-01',
        'moving_party' => 'Test Plaintiff',
        'summary' => 'Motion for summary judgment'
      }
      
      # Call generate_filename
      result = app.new.send(:generate_filename, doc_info)
      
      # Verify filename format
      expect(result).to include('PL_TestPlaintiff_MOT')
      expect(result).to include('04-01-2024')
    end

    it 'organizes files into folder structure' do
      # Mock doc_info
      doc_info = {
        'document_type' => 'motion',
        'filing_date' => '2024-04-01',
        'moving_party' => 'Test Plaintiff',
        'docket_number' => 'CV-2024-1234',
        'summary' => 'Motion for summary judgment'
      }
      
      # Mock FileUtils.mkdir_p and FileUtils.cp
      allow(FileUtils).to receive(:mkdir_p)
      allow(FileUtils).to receive(:cp)
      
      # Call organize_files
      app.new.send(:organize_files, doc_info, 'original.pdf', 'test_output')
      
      # Verify directory structure was created
      expect(FileUtils).to have_received(:mkdir_p).with(
        File.join('test_output', 'CV-2024-1234', 'Test_Plaintiff', 'motion', '2024-04-01')
      )
    end
  end

  describe 'Database Operations' do
    it 'saves document info to database' do
      # Mock doc_info
      doc_info = {
        'document_type' => 'motion',
        'filing_date' => '2024-04-01',
        'moving_party' => 'Test Plaintiff',
        'court' => 'Test Court',
        'judge' => 'Judge Test',
        'docket_number' => 'CV-2024-1234',
        'summary' => 'Motion for summary judgment'
      }
      
      # Call save_to_database
      result = app.new.send(:save_to_database, doc_info, 'original.pdf', 'new.pdf')
      
      # Verify document was saved to database
      expect(result).to eq(true)
      
      # Check database
      db = SQLite3::Database.new('lawpaw_test.db')
      document = db.execute("SELECT * FROM legal_documents WHERE filename = 'new.pdf'").first
      db.close
      
      expect(document).not_to be_nil
    end
  end

  describe 'Document Routes' do
    before(:each) do
      # Create test document in database
      db = SQLite3::Database.new('lawpaw_test.db')
      db.execute(
        "INSERT INTO legal_documents 
         (id, user_id, filename, original_path, new_path, document_type, filing_date, moving_party, court, judge, docket_number, summary) 
         VALUES (1, 1, 'test.pdf', '/original/test.pdf', '/new/test.pdf', 'motion', '2024-04-01', 'Test Plaintiff', 'Test Court', 'Judge Test', 'CV-2024-1234', 'Test summary')"
      )
      db.close
    end
    
    it 'shows documents page with user documents' do
      # Mock get_user_documents
      allow_any_instance_of(Dood).to receive(:get_user_documents).and_return([
        {
          'id' => 1,
          'filename' => 'test.pdf',
          'document_type' => 'motion',
          'filing_date' => '2024-04-01'
        }
      ])
      
      allow_any_instance_of(Dood).to receive(:erb).with(:documents).and_return('Documents Page')
      
      get '/documents'
      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to be_empty
    end
    
    it 'shows document details' do
      allow_any_instance_of(Dood).to receive(:erb).with(:document_details).and_return('Document Details Page')
      
      get '/documents/1'
      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to be_empty
    end
  end
  
  describe 'Processing Documents from Various Sources' do
    it 'processes local documents' do
      # Mock run_bulk_extractor
      allow_any_instance_of(Dood).to receive(:run_bulk_extractor).and_return(['test.pdf'])
      
      # Mock ocr_first_page
      allow_any_instance_of(Dood).to receive(:ocr_first_page).and_return('Test OCR text')
      
      # Mock analyze_document_with_openai
      allow_any_instance_of(Dood).to receive(:analyze_document_with_openai).and_return({
        'document_type' => 'motion',
        'filing_date' => '2024-04-01',
        'moving_party' => 'Test Plaintiff',
        'docket_number' => 'CV-2024-1234',
        'summary' => 'Test summary'
      })
      
      # Mock organize_files
      allow_any_instance_of(Dood).to receive(:organize_files).and_return('/path/to/new.pdf')
      
      # Mock save_to_database
      allow_any_instance_of(Dood).to receive(:save_to_database).and_return(true)
      
      # Mock save_to_csv
      allow_any_instance_of(Dood).to receive(:save_to_csv).and_return(true)
      
      # Mock FileUtils.mkdir_p
      allow(FileUtils).to receive(:mkdir_p).and_return(true)
      
      # Mock Dir.exist?
      allow(Dir).to receive(:exist?).and_return(true)
      
      # Test processing local documents
      post '/process', {
        source_type: 'local',
        input_folder: '/test/path',
        keyword: 'test_keyword'
      }
      
      expect(last_response.status).to eq(200)
      response = JSON.parse(last_response.body)
      expect(response['message']).to include('Processed')
    end
  end
end
