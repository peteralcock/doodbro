# Legal Document Processor

A Ruby Sinatra application that processes legal documents by:

1. Finding PDFs containing specific keywords using `bulk_extractor`
2. OCRing the first page using Tesseract
3. Analyzing the document content with OpenAI's API
4. Organizing files by docket number, parties, filing type, and date
5. Creating a searchable database of processed documents

## Features

- Search for PDFs containing specific keywords
- Extract text from the top half of the first page using OCR
- Use OpenAI's GPT-4o model to analyze legal documents
- Identify document type, filing date, moving party, court, judge, docket number, etc.
- Generate standardized filenames based on document content
- Organize files into a logical folder structure
- Store document metadata in SQLite database
- Export results to CSV

## Requirements

- Ruby 3.2+
- Tesseract OCR
- ImageMagick
- pdftk
- bulk_extractor
- SQLite3
- OpenAI API key

## Installation

### Using Docker

```bash
# Build the Docker image
docker build -t legal-document-processor .

# Run the container
docker run -p 4567:4567 -e OPENAI_API_KEY=your-api-key-here legal-document-processor
```

### Manual Installation

```bash
# Install system dependencies
# For Ubuntu/Debian:
sudo apt-get update
sudo apt-get install -y tesseract-ocr tesseract-ocr-eng imagemagick pdftk bulk_extractor sqlite3

# For macOS:
brew install tesseract imagemagick pdftk-java bulk_extractor sqlite

# Install Ruby dependencies
bundle install

# Set your OpenAI API key
export OPENAI_API_KEY=your-api-key-here

# Run the application
ruby app.rb
```

## Usage

1. Visit `http://localhost:4567/legal` in your web browser
2. Enter the input folder containing PDFs to process
3. Enter the output folder where processed files will be stored
4. Enter a keyword to search for
5. Click "Process Files" to start processing
6. View results and download CSV report when complete

## API Endpoints

- `GET /` -
