# Example Dockerfile for building a Ruby application with TruffleRuby
#
# This example shows how to use the truffleruby-native base image
# for your own Ruby applications.
#
# Prerequisites:
# 1. Build the base image first:
#    docker build -f tool/dockerfiles/build-native.dockerfile \
#                 --target runtime -t truffleruby-native:runtime .
#
# 2. Then build your app:
#    docker build -f tool/dockerfiles/example-app.dockerfile -t myapp .

# Use the TruffleRuby native runtime as base
# Replace with your actual image name/tag
ARG TRUFFLERUBY_IMAGE=truffleruby-native:runtime
FROM ${TRUFFLERUBY_IMAGE}

# Set working directory
WORKDIR /app

# Install bundler if needed (usually already included)
# RUN gem install bundler

# Copy Gemfile and Gemfile.lock first for better layer caching
COPY Gemfile Gemfile.lock ./

# Install dependencies
# Use --deployment for production-like install
# Use --without development test to skip dev/test gems
RUN bundle config set --local deployment true && \
    bundle config set --local without 'development test' && \
    bundle install --jobs 4 --retry 3

# Copy application code
COPY . .

# Precompile assets if using Rails (uncomment if needed)
# RUN bundle exec rake assets:precompile

# Set environment variables
ENV RACK_ENV=production \
    RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=true

# Expose port (adjust as needed)
EXPOSE 3000

# Run the application
# Adjust the command for your framework (Rails, Sinatra, etc.)
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
