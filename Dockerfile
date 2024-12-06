FROM ruby:3.3.5

RUN apt update && apt install -y default-mysql-client
