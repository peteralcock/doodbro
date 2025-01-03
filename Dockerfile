FROM ruby:3.2-slim
RUN apt-get update -qq && apt-get install -y build-essential libsqlite3-dev nodejs
WORKDIR /app
COPY Gemfile Gemfile.lock /app/
RUN bundle install
COPY . /app
EXPOSE 4567
CMD ["ruby", "app.rb"]
