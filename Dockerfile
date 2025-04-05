FROM ruby:3.2-slim

# Install dependencies
RUN apt-get update -qq && \
    apt-get install -y build-essential libsqlite3-dev nodejs tesseract-ocr \
    imagemagick pdftk bulk_extractor

# Set up working directory
WORKDIR /app

# Copy Gemfile and install gems
COPY Gemfile Gemfile.lock /app/
RUN bundle install

# Copy application code
COPY . /app

# Expose port
EXPOSE 4567

# Run the application
CMD ["ruby", "app.rb"]
