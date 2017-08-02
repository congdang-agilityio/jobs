FROM ruby:2.3-alpine
# Update information about packages
RUN apk update
# Install bash in case you want to provide some work inside containe
# For example:
#     docker run -i -t name_of_your_image bash
RUN apk add bash

# g++ and make for gems building
RUN apk add g++ make

# Timezone data - required by Rails
RUN apk add tzdata

# Install bundler
RUN gem install bundler rake
# Install all gems and cache them

ENV APP_HOME /usr/src/app
RUN mkdir $APP_HOME

WORKDIR $APP_HOME

ADD Gemfile* $APP_HOME/

# --- Add this to your Dockerfile ---
ENV BUNDLE_GEMFILE=$APP_HOME/Gemfile \
  BUNDLE_JOBS=2 \
  BUNDLE_PATH=/bundle

RUN bundle install

ADD . $APP_HOME

CMD bundle exec ruby bin/runner
