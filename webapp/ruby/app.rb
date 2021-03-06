require 'sinatra'
require 'mysql2'
require 'mysql2-cs-bind'
require 'csv'

class App < Sinatra::Base
  LIMIT = 20
  NAZOTTE_LIMIT = 50
  CHAIR_SEARCH_CONDITION = JSON.parse(File.read('../fixture/chair_condition.json'), symbolize_names: true)
  CHAIR_SEARCH_CONDITION_JSON = CHAIR_SEARCH_CONDITION.to_json
  ESTATE_SEARCH_CONDITION = JSON.parse(File.read('../fixture/estate_condition.json'), symbolize_names: true)
  ESTATE_SEARCH_CONDITION_JSON = ESTATE_SEARCH_CONDITION.to_json

  configure :development do
    require 'sinatra/reloader'
    register Sinatra::Reloader
  end

  configure do
    # enable :logging
  end

  set :add_charset, ['application/json']

  helpers do
    def db_info
      {
        host: ENV.fetch('MYSQL_HOST', '127.0.0.1'),
        host_b: ENV.fetch('MYSQL_B_HOST', '127.0.0.1'),
        port: ENV.fetch('MYSQL_PORT', '3306'),
        username: ENV.fetch('MYSQL_USER', 'isucon'),
        password: ENV.fetch('MYSQL_PASS', 'isucon'),
        database: ENV.fetch('MYSQL_DBNAME', 'isuumo'),
      }
    end

    def db_estate
      Thread.current[:db_estate] ||= Mysql2::Client.new(
        host: db_info[:host],
        port: db_info[:port],
        username: db_info[:username],
        password: db_info[:password],
        database: db_info[:database],
        reconnect: true,
        symbolize_keys: true,
      )
    end

    def db_chair
      Thread.current[:db_chair] ||= Mysql2::Client.new(
          host: db_info[:host_b],
          port: db_info[:port],
          username: db_info[:username],
          password: db_info[:password],
          database: db_info[:database],
          reconnect: true,
          symbolize_keys: true,
      )
    end

    def transaction_estate(name)
      begin_transaction_estate(name)
      yield(name)
      commit_transaction_estate(name)
    rescue Exception => e
      logger.error "Failed to commit tx: #{e.inspect}"
      rollback_transaction_estate(name)
      raise
    ensure
      ensure_to_abort_transaction_estate(name)
    end

    def transaction_chair(name)
      begin_transaction_chair(name)
      yield(name)
      commit_transaction_chair(name)
    rescue Exception => e
      logger.error "Failed to commit tx: #{e.inspect}"
      rollback_transaction_chair(name)
      raise
    ensure
      ensure_to_abort_transaction_chair(name)
    end

    def begin_transaction_estate(name)
      Thread.current[:db_transaction] ||= {}
      db_estate.query('BEGIN')
      Thread.current[:db_transaction][name] = :open
    end

    def begin_transaction_chair(name)
      Thread.current[:db_transaction] ||= {}
      db_chair.query('BEGIN')
      Thread.current[:db_transaction][name] = :open
    end

    def commit_transaction_estate(name)
      Thread.current[:db_transaction] ||= {}
      db_estate.query('COMMIT')
      Thread.current[:db_transaction][name] = :nil
    end

    def commit_transaction_chair(name)
      Thread.current[:db_transaction] ||= {}
      db_chair.query('COMMIT')
      Thread.current[:db_transaction][name] = :nil
    end

    def rollback_transaction_estate(name)
      Thread.current[:db_transaction] ||= {}
      db_estate.query('ROLLBACK')
      Thread.current[:db_transaction][name] = :nil
    end

    def rollback_transaction_chair(name)
      Thread.current[:db_transaction] ||= {}
      db_chair.query('ROLLBACK')
      Thread.current[:db_transaction][name] = :nil
    end

    def ensure_to_abort_transaction_estate(name)
      Thread.current[:db_transaction] ||= {}
      if in_transaction?(name)
        logger.warn "Transaction closed implicitly (#{$$}, #{Thread.current.object_id}): #{name}"
        rollback_transaction_estate(name)
      end
    end

    def ensure_to_abort_transaction_chair(name)
      Thread.current[:db_transaction] ||= {}
      if in_transaction?(name)
        logger.warn "Transaction closed implicitly (#{$$}, #{Thread.current.object_id}): #{name}"
        rollback_transaction_chair(name)
      end
    end

    def in_transaction?(name)
      Thread.current[:db_transaction] && Thread.current[:db_transaction][name] == :open
    end

    def camelize_keys_for_estate(estate_hash)
      estate_hash.tap do |e|
        e.delete(:point)
        e[:doorHeight] = e.delete(:door_height)
        e[:doorWidth] = e.delete(:door_width)
      end
    end

    def body_json_params
      @body_json_params ||= JSON.parse(request.body.tap(&:rewind).read, symbolize_names: true)
    rescue JSON::ParserError => e
      logger.error "Failed to parse body: #{e.inspect}"
      halt 400
    end
  end

  post '/initialize' do
    sql_dir = Pathname.new('../mysql/db')
    %w[0_Schema.sql 1_DummyEstateData.sql 2_DummyChairData.sql].each do |sql|
      sql_path = sql_dir.join(sql)
      cmd = ['mysql', '-h', db_info[:host], '-u', db_info[:username], "-p#{db_info[:password]}", '-P', db_info[:port], db_info[:database]]
      cmd2 = ['mysql', '-h', db_info[:host_b], '-u', db_info[:username], "-p#{db_info[:password]}", '-P', db_info[:port], db_info[:database]]
      IO.popen(cmd, 'w') do |io|
        io.puts File.read(sql_path)
        io.close
      end
      IO.popen(cmd2, 'w') do |io|
        io.puts File.read(sql_path)
        io.close
      end
    end

    { language: 'ruby' }.to_json
  end

  get '/api/chair/low_priced' do
    sql = "SELECT * FROM chair WHERE stock > 0 ORDER BY price ASC, id ASC LIMIT #{LIMIT}" # XXX:
    chairs = db_chair.query(sql).to_a
    { chairs: chairs }.to_json
  end

  get '/api/chair/search' do
    search_queries = []
    query_params = []

    if params[:priceRangeId] && params[:priceRangeId].size > 0
      chair_price = CHAIR_SEARCH_CONDITION[:price][:ranges][params[:priceRangeId].to_i]
      unless chair_price
        logger.error "priceRangeID invalid: #{params[:priceRangeId]}"
        halt 400
      end

      if chair_price[:min] != -1
        search_queries << 'price >= ?'
        query_params << chair_price[:min]
      end

      if chair_price[:max] != -1
        search_queries << 'price < ?'
        query_params << chair_price[:max]
      end
    end

    if params[:heightRangeId] && params[:heightRangeId].size > 0
      chair_height = CHAIR_SEARCH_CONDITION[:height][:ranges][params[:heightRangeId].to_i]
      unless chair_height
        logger.error "heightRangeId invalid: #{params[:heightRangeId]}"
        halt 400
      end

      if chair_height[:min] != -1
        search_queries << 'height >= ?'
        query_params << chair_height[:min]
      end

      if chair_height[:max] != -1
        search_queries << 'height < ?'
        query_params << chair_height[:max]
      end
    end

    if params[:widthRangeId] && params[:widthRangeId].size > 0
      chair_width = CHAIR_SEARCH_CONDITION[:width][:ranges][params[:widthRangeId].to_i]
      unless chair_width
        logger.error "widthRangeId invalid: #{params[:widthRangeId]}"
        halt 400
      end

      if chair_width[:min] != -1
        search_queries << 'width >= ?'
        query_params << chair_width[:min]
      end

      if chair_width[:max] != -1
        search_queries << 'width < ?'
        query_params << chair_width[:max]
      end
    end

    if params[:depthRangeId] && params[:depthRangeId].size > 0
      chair_depth = CHAIR_SEARCH_CONDITION[:depth][:ranges][params[:depthRangeId].to_i]
      unless chair_depth
        logger.error "depthRangeId invalid: #{params[:depthRangeId]}"
        halt 400
      end

      if chair_depth[:min] != -1
        search_queries << 'depth >= ?'
        query_params << chair_depth[:min]
      end

      if chair_depth[:max] != -1
        search_queries << 'depth < ?'
        query_params << chair_depth[:max]
      end
    end

    if params[:kind] && params[:kind].size > 0
      search_queries << 'kind = ?'
      query_params << params[:kind]
    end

    if params[:color] && params[:color].size > 0
      search_queries << 'color = ?'
      query_params << params[:color]
    end

    if params[:features] && params[:features].size > 0
      params[:features].split(',').each do |feature_condition|
        search_queries << "features LIKE CONCAT('%', ?, '%')"
        query_params.push(feature_condition)
      end
    end

    if search_queries.size == 0
      logger.error "Search condition not found"
      halt 400
    end

    search_queries.push('stock > 0')

    page =
      begin
        Integer(params[:page], 10)
      rescue ArgumentError => e
        logger.error "Invalid format page parameter: #{e.inspect}"
        halt 400
      end

    per_page =
      begin
        Integer(params[:perPage], 10)
      rescue ArgumentError => e
        logger.error "Invalid format perPage parameter: #{e.inspect}"
        halt 400
      end

    sqlprefix = 'SELECT * FROM chair WHERE '
    search_condition = search_queries.join(' AND ')
    limit_offset = " ORDER BY rev_popularity ASC, id ASC LIMIT #{per_page} OFFSET #{per_page * page}" # XXX: mysql-cs-bind doesn't support escaping variables for limit and offset
    count_prefix = 'SELECT COUNT(*) as count FROM chair WHERE '

    count = db_chair.xquery("#{count_prefix}#{search_condition}", query_params).first[:count]
    chairs = db_chair.xquery("#{sqlprefix}#{search_condition}#{limit_offset}", query_params).to_a

    { count: count, chairs: chairs }.to_json
  end

  get '/api/chair/:id' do
    id =
      begin
        Integer(params[:id], 10)
      rescue ArgumentError => e
        logger.error "Request parameter \"id\" parse error: #{e.inspect}"
        halt 400
      end

    chair = db_chair.xquery('SELECT * FROM chair WHERE id = ?', id).first
    unless chair
      logger.info "Requested id's chair not found: #{id}"
      halt 404
    end

    if chair[:stock] <= 0
      logger.info "Requested id's chair is sold out: #{id}"
      halt 404
    end

    chair.to_json
  end

  post '/api/chair' do
    if !params[:chairs] || !params[:chairs].respond_to?(:key) || !params[:chairs].key?(:tempfile)
      logger.error 'Failed to get form file'
      halt 400
    end

    chairs = []
    CSV.parse(params[:chairs][:tempfile].read, skip_blanks: true) do |row|
      chair = *row.map { |data| "'#{data}'"}
      chairs << "(#{chair.join(',')})"
    end

    transaction_chair('post_api_chair') do
      sql = "INSERT INTO chair(id, name, description, thumbnail, price, height, width, depth, color, features, kind, popularity, stock) VALUES #{chairs.join(",")}"
      db_chair.query(sql)
    end

    status 201
  end

  post '/api/chair/buy/:id' do
    unless body_json_params[:email]
      logger.error 'post buy chair failed: email not found in request body'
      halt 400
    end

    id =
      begin
        Integer(params[:id], 10)
      rescue ArgumentError => e
        logger.error "post buy chair failed: #{e.inspect}"
        halt 400
      end

    chair = db_chair.xquery('SELECT * FROM chair WHERE id = ?', id).first
    halt 404 unless chair

    transaction_chair('post_api_chair_buy') do |tx_name|
      db_chair.xquery('UPDATE chair SET stock = stock - 1 WHERE id = ? AND stock > 0', id)
    end

    status 200
  end

  get '/api/chair/search/condition' do
    CHAIR_SEARCH_CONDITION_JSON
  end

  get '/api/estate/low_priced' do
    sql = "SELECT * FROM estate ORDER BY rent ASC, id ASC LIMIT #{LIMIT}" # XXX:
    estates = db_estate.xquery(sql).to_a
    { estates: estates.map { |e| camelize_keys_for_estate(e) } }.to_json
  end

  get '/api/estate/search' do
    search_queries = []
    query_params = []

    if params[:doorHeightRangeId] && params[:doorHeightRangeId].size > 0
      door_height = ESTATE_SEARCH_CONDITION[:doorHeight][:ranges][params[:doorHeightRangeId].to_i]
      unless door_height
        logger.error "doorHeightRangeId invalid: #{params[:doorHeightRangeId]}"
        halt 400
      end

      if door_height[:min] != -1
        search_queries << 'door_height >= ?'
        query_params << door_height[:min]
      end

      if door_height[:max] != -1
        search_queries << 'door_height < ?'
        query_params << door_height[:max]
      end
    end

    if params[:doorWidthRangeId] && params[:doorWidthRangeId].size > 0
      door_width = ESTATE_SEARCH_CONDITION[:doorWidth][:ranges][params[:doorWidthRangeId].to_i]
      unless door_width
        logger.error "doorWidthRangeId invalid: #{params[:doorWidthRangeId]}"
        halt 400
      end

      if door_width[:min] != -1
        search_queries << 'door_width >= ?'
        query_params << door_width[:min]
      end

      if door_width[:max] != -1
        search_queries << 'door_width < ?'
        query_params << door_width[:max]
      end
    end

    if params[:rentRangeId] && params[:rentRangeId].size > 0
      rent = ESTATE_SEARCH_CONDITION[:rent][:ranges][params[:rentRangeId].to_i]
      unless rent
        logger.error "rentRangeId invalid: #{params[:rentRangeId]}"
        halt 400
      end

      if rent[:min] != -1
        search_queries << 'rent >= ?'
        query_params << rent[:min]
      end

      if rent[:max] != -1
        search_queries << 'rent < ?'
        query_params << rent[:max]
      end
    end

    if params[:features] && params[:features].size > 0
      params[:features].split(',').each do |feature_condition|
        search_queries << "features LIKE CONCAT('%', ?, '%')"
        query_params.push(feature_condition)
      end
    end

    if search_queries.size == 0
      logger.error "Search condition not found"
      halt 400
    end

    page =
      begin
        Integer(params[:page], 10)
      rescue ArgumentError => e
        logger.error "Invalid format page parameter: #{e.inspect}"
        halt 400
      end

    per_page =
      begin
        Integer(params[:perPage], 10)
      rescue ArgumentError => e
        logger.error "Invalid format perPage parameter: #{e.inspect}"
        halt 400
      end

    sqlprefix = 'SELECT * FROM estate WHERE '
    search_condition = search_queries.join(' AND ')
    limit_offset = " ORDER BY rev_popularity ASC, id ASC LIMIT #{per_page} OFFSET #{per_page * page}" # XXX:
    count_prefix = 'SELECT COUNT(*) as count FROM estate WHERE '

    count = db_estate.xquery("#{count_prefix}#{search_condition}", query_params).first[:count]
    estates = db_estate.xquery("#{sqlprefix}#{search_condition}#{limit_offset}", query_params).to_a

    { count: count, estates: estates.map { |e| camelize_keys_for_estate(e) } }.to_json
  end

  post '/api/estate/nazotte' do
    coordinates = body_json_params[:coordinates]

    unless coordinates
      logger.error "post search estate nazotte failed: coordinates not found"
      halt 400
    end

    if !coordinates.is_a?(Array) || coordinates.empty?
      logger.error "post search estate nazotte failed: coordinates are empty"
      halt 400
    end

    coordinates_to_text = "'POLYGON((%s))'" % coordinates.map { |c| '%f %f' % c.values_at(:latitude, :longitude) }.join(',')
    sql = 'SELECT * FROM estate WHERE ST_Contains(ST_PolygonFromText(%s), point) ORDER BY rev_popularity, id LIMIT %s' % [coordinates_to_text, NAZOTTE_LIMIT]
    nazotte_estates = db_estate.query(sql).to_a
    {
      estates: nazotte_estates.map { |e| camelize_keys_for_estate(e) },
      count: nazotte_estates.size,
    }.to_json
  end

  get '/api/estate/:id' do
    id =
      begin
        Integer(params[:id], 10)
      rescue ArgumentError => e
        logger.error "Request parameter \"id\" parse error: #{e.inspect}"
        halt 400
      end

    estate = db_estate.xquery('SELECT * FROM estate WHERE id = ?', id).first
    unless estate
      logger.info "Requested id's estate not found: #{id}"
      halt 404
    end

    camelize_keys_for_estate(estate).to_json
  end

  post '/api/estate' do
    unless params[:estates]
      logger.error 'Failed to get form file'
      halt 400
    end

    estates = []
    CSV.parse(params[:estates][:tempfile].read, skip_blanks: true) do |row|
      estate = *row.map { |data| "'#{data}'"}
      estates << "(#{estate.join(',')})"
    end

    transaction_estate('post_api_estate') do
      sql = "INSERT INTO estate(id, name, description, thumbnail, address, latitude, longitude, rent, door_height, door_width, features, popularity) VALUES #{estates.join(',')}"
      db_estate.query(sql)
    end

    status 201
  end

  post '/api/estate/req_doc/:id' do
    unless body_json_params[:email]
      logger.error 'post request document failed: email not found in request body'
      halt 400
    end

    id =
      begin
        Integer(params[:id], 10)
      rescue ArgumentError => e
        logger.error "post request document failed: #{e.inspect}"
        halt 400
      end

    estate = db_estate.xquery('SELECT * FROM estate WHERE id = ?', id).first
    unless estate
      logger.error "Requested id's estate not found: #{id}"
      halt 404
    end

    status 200
  end

  get '/api/estate/search/condition' do
    ESTATE_SEARCH_CONDITION_JSON
  end

  get '/api/recommended_estate/:id' do
    id =
      begin
        Integer(params[:id], 10)
      rescue ArgumentError => e
        logger.error "Request parameter \"id\" parse error: #{e.inspect}"
        halt 400
      end

    chair = db_chair.xquery('SELECT * FROM chair WHERE id = ?', id).first
    unless chair
      logger.error "Requested id's chair not found: #{id}"
      halt 404
    end

    w = chair[:width]
    h = chair[:height]
    d = chair[:depth]

    sql = "SELECT * FROM estate WHERE (door_width >= ? AND door_height >= ?) OR (door_width >= ? AND door_height >= ?) OR (door_width >= ? AND door_height >= ?) OR (door_width >= ? AND door_height >= ?) OR (door_width >= ? AND door_height >= ?) OR (door_width >= ? AND door_height >= ?) ORDER BY rev_popularity ASC, id ASC LIMIT #{LIMIT}" # XXX:
    estates = db_estate.xquery(sql, w, h, w, d, h, w, h, d, d, w, d, h).to_a

    { estates: estates.map { |e| camelize_keys_for_estate(e) } }.to_json
  end
end
