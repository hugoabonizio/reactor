require 'tcp_handler'
require 'unicorn_http'
require 'rack'

class Reactor::HTTPHandler < Reactor::TCPHandler

	attr_accessor :keepalive

	MAX_HEADER = 8 * 1024
	MAX_BODY = 8 * 1024

	LOCALHOST = '127.0.0.1'.freeze
	REMOTE_ADDR = 'REMOTE_ADDR'.freeze
	KEEP_ALIVE = 'Keep-Alive'.freeze
	CLOSE = 'Close'.freeze 

  DEFAULTS = {
    "rack.errors" => STDERR,
    "rack.multiprocess" => true,
    "rack.multithread" => false,
    "rack.run_once" => false,
    "rack.version" => [1, 0],
    "SCRIPT_NAME" => "",
  }

  # Every standard HTTP code mapped to the appropriate message.
  HTTP_CODES = Rack::Utils::HTTP_STATUS_CODES.inject({}) { |hash,(code,msg)|
    hash[code] = "#{code} #{msg}"
    hash
  }

	def post_init
		@data = ''
		@env = {}
		@parser = HttPParser.new		
		@keepalive = false
    @env[REMOTE_ADDR] = @conn === TCPSocket ? @conn.peeraddr.last : LOCALHOST
	end

	def data_received(data)
		@data << data
		if @data.length > MAx_HEADER
			# we need to log this incident
			close!
			return
		end
		if @parser.headers(@env, @data)
			# if we get here then the request headers were succssefuly parsed
			# now is a good time to check for keep alive
			handle_http_request
		end

	end

	def handle_http_request
      response = app.call(env = REQUEST.read(client))
      if 100 == response.first.to_i
        client.write(Const::EXPECT_100_RESPONSE)
        env.delete(Const::HTTP_EXPECT)
        response = app.call(env)
      end
      HttpResponse.write(client, response, HttpRequest::PARSER.headers?)		
	end

	# we will attempt to compose the headers and the body
	# if they both fit within the chunk size then we will
	# attempt to send them right away, else we will send them
	# off the current tick via the reactor
	def send_http_response(status, headers, body)
		headers['Date'] = Time.now.httpdate
		headers['Status'] = HTTP_CODES[status.to_i] || status
		headers['Connection'] = @keepalive ? KEEP_ALIVE : CLOSE
		response = "HTTP/1.1 #{status}\r\n"
		headers.each do |key, value|
      response << if value =~ /\n/
										(value.split(/\n/).map!{|v| "#{key}: #{v}\r\n" }).join('')
									else
										"#{key}: #{value}\r\n"
									end
    end
		response << "\r\n"
		unless body.empty?
			# we have a body let's grab a chunk 
			# from it and add it to the response
			# ...
			# but how do I get a chunk?
			# Rack only defines #each on the body
			# should I use an external iterator? (yikes!)
		end	
		write(response)
		finish
 	end

	def finish
		close unless @keepalive	
	end

end
