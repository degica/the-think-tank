workers Integer(ENV['WEB_CONCURRENCY'] || 4)
threads_count = Integer(ENV['THREAD_COUNT'] || 64)
threads threads_count, threads_count

rackup 'config.ru'

port        ENV['PORT']     || 8080
environment ENV['RACK_ENV'] || 'production'
