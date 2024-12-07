require 'sinatra/base'
require 'mysql2'
require 'mysql2-cs-bind'
require 'erubi'
require 'dotenv/load' if ENV['DOTENV']
require 'debug' if ENV['DOTENV']
require 'redis'

module Ishocon1
  class AuthenticationError < StandardError; end
  class PermissionDenied < StandardError; end
end

DB_CONFIG = {
  host: ENV['ISHOCON1_DB_HOST'] || '127.0.0.1',
  port: ENV['ISHOCON1_DB_PORT']&.to_i || 3306,
  username: ENV['ISHOCON1_DB_USER'] || 'ishocon',
  password: ENV['ISHOCON1_DB_PASSWORD'] || '',
  database: ENV['ISHOCON1_DB_NAME'] || 'ishocon1',
  reconnect: true
}

# def get_product(id)
#   Marshal.load($redis.get("product_#{id}"))
# end
#
# def set_product(product)
#   $redis.set("product_#{product[:id]}", Marshal.dump(product))
# end

def cache(key, &block)
  hit = $redis.get(key)
  return hit if hit

  value = block.call
  $redis.set(key, value)
  value
end

class Ishocon1::WebApp < Sinatra::Base
  session_secret = ENV['ISHOCON1_SESSION_SECRET'] || 'showwin_happy' * 10
  use Rack::Session::Cookie, key: 'rack.session', secret: session_secret
  set :erb, escape_html: true
  set :public_folder, File.expand_path('../public', __FILE__)
  set :protection, true
  

  configure do
    $redis = Redis.new(host: 'localhost', port: 6379)
    # $redis = Redis.new(host: 'redis', port: 6379)

    data = File.read("bigdata.marshal")
    $all_products = Marshal.load(data)
    $all_products.each do |key, value|
      $redis.set("product_#{key}", Marshal.dump(value))
    end

    config = { db: DB_CONFIG }

    client = Mysql2::Client.new(
      host: config[:db][:host],
      port: config[:db][:port],
      username: config[:db][:username],
      password: config[:db][:password],
      database: config[:db][:database],
      reconnect: true
    )
    client.query_options.merge!(symbolize_keys: true)

    $all_users = {}
    $all_users_by_email = {}
    client.xquery('SELECT * FROM users').each do |user|
      $all_users[user[:id]] = user.to_hash
      $all_users_by_email[user[:email]] = user.to_hash
    end

    client.close
  end

  helpers do
    def config
      @config ||= {
        db: DB_CONFIG
      }
    end

    def db
      return Thread.current[:ishocon1_db] if Thread.current[:ishocon1_db]
      client = Mysql2::Client.new(
        host: config[:db][:host],
        port: config[:db][:port],
        username: config[:db][:username],
        password: config[:db][:password],
        database: config[:db][:database],
        reconnect: true
      )
      client.query_options.merge!(symbolize_keys: true)
      Thread.current[:ishocon1_db] = client


      client
    end

    def time_now_db
      Time.now - 9 * 60 * 60
    end

    def authenticate(email, password)
      user = $all_users_by_email[email]
      fail Ishocon1::AuthenticationError unless user.nil? == false && user[:password] == password
      session[:user_id] = user[:id]
    end

    def authenticated!
      fail Ishocon1::PermissionDenied unless current_user
    end

    def current_user
      $all_users[session[:user_id].to_i]
    end

    # def update_last_login(user_id)
    #   db.xquery('UPDATE users SET last_login = ? WHERE id = ?', time_now_db, user_id)
    # end

    def buy_product(product_id, user_id)
      db.xquery('INSERT INTO histories (product_id, user_id, created_at) VALUES (?, ?, ?)', \
        product_id, user_id, time_now_db)
    end

    def already_bought?(product_id)
      return false unless current_user
      count = db.xquery('SELECT count(*) as count FROM histories WHERE product_id = ? AND user_id = ?', \
                        product_id, current_user[:id]).first[:count]
      count > 0
    end

    def create_comment(product_id, user_id, content)
      db.xquery('INSERT INTO comments (product_id, user_id, content, created_at) VALUES (?, ?, ?, ?)', \
        product_id, user_id, content, time_now_db)
    end
  end

  error Ishocon1::AuthenticationError do
    session[:user_id] = nil
    halt 401, erb(:login, layout: false, locals: { message: 'ログインに失敗しました' })
  end

  error Ishocon1::PermissionDenied do
    halt 403, erb(:login, layout: false, locals: { message: '先にログインをしてください' })
  end

  get '/login' do
    session.clear
    erb :login, layout: false, locals: { message: 'ECサイトで爆買いしよう！！！！' }
  end

  post '/login' do
    authenticate(params['email'], params['password'])
    # update_last_login(current_user[:id])
    redirect '/'
  end

  get '/logout' do
    session[:user_id] = nil
    session.clear
    redirect '/login'
  end

  get '/' do
    page = params[:page].to_i || 0
    limit = 50
    offset = page * limit

    # Fetch products with pagination
    products = $all_products.values[offset, limit]

    # Get product IDs for batch fetching comments and counts
    product_ids = products.map { |p| p[:id] }
    
    # Fetch comments for all products in one query
    comments = db.xquery(<<~SQL) #, product_ids)
      SELECT c.*, c.product_id
      FROM comments AS c
      WHERE c.product_id IN (#{product_ids.join(',')})
      ORDER BY c.product_id, c.created_at DESC
    SQL
    
    # Fetch comment counts for all products in one query
    comment_counts = db.xquery(<<~SQL) # , product_ids)
      SELECT product_id, COUNT(*) AS count
      FROM comments
      WHERE product_id IN (#{product_ids.join(',')})
      GROUP BY product_id
    SQL
    
    # Transform comment counts into a hash for quick lookup
    comment_counts_by_product = comment_counts.each_with_object({}) do |row, hash|
      hash[row[:product_id]] = row[:count]
    end
    
    # Group comments by product_id for quick lookup
    comments_by_product = comments.group_by { |c| c[:product_id] }

    erb :index, locals: {
      products: products,
      comments_by_product: comments_by_product,
      comment_counts_by_product: comment_counts_by_product
    }
  end

  get '/users/:user_id' do
    products_query = <<SQL
SELECT p.id, p.name, p.description, p.image_path, p.price, h.created_at
FROM histories as h
LEFT OUTER JOIN products as p
ON h.product_id = p.id
WHERE h.user_id = ?
ORDER BY h.id DESC
SQL
    # products = cache("/users/#{params[:user_id]}") {
    products = db.xquery(products_query, params[:user_id])

    total_pay = 0
    products.each do |product|
      total_pay += product[:price]
    end

    user = $all_users[params[:user_id].to_i]
    erb :mypage, locals: { products: products, user: user, total_pay: total_pay }
  end

  get '/products/:product_id' do
    product = $all_products[params[:product_id].to_i]
    erb :product, locals: { product: product, comments: [] }
  end

  post '/products/buy/:product_id' do
    authenticated!
    buy_product(params[:product_id], current_user[:id])
    redirect "/users/#{current_user[:id]}"
  end

  post '/comments/:product_id' do
    authenticated!
    create_comment(params[:product_id], current_user[:id], params[:content])
    redirect "/users/#{current_user[:id]}"
  end

  get '/initialize' do
    db.query('DELETE FROM users WHERE id > 5000')
    db.query('DELETE FROM products WHERE id > 10000')
    db.query('DELETE FROM comments WHERE id > 200000')
    db.query('DELETE FROM histories WHERE id > 500000')
    "Finish"
  end
end
