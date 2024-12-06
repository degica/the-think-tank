require_relative './app.rb'
require 'rack/cache'

use Rack::Static, :urls => ["/css", "/images"], :root => "public"

use Rack::Cache,
  metastore:    'file:/tmp/cache/rack/meta',
  entitystore:  'file:/tmp/cache/rack/body',
  verbose:      true

run Ishocon1::WebApp
