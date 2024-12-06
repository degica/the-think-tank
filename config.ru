require_relative './app.rb'

use Rack::Static, :urls => ["/css", "/images"], :root => "public"
run Ishocon1::WebApp
