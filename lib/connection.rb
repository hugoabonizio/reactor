class Reactor::Connection

	attr_reader :last_active
	attr_writer :streaming

	CHUNK_SIZE = 64 * 1024
	TIMEOUT = 120
	CHUNK_SIZE = 64 * 1024

	def initialize(conn, server, reactor)
		@conn, @server, @reactor = conn, server, reactor
		@write_buffer, @last_active = '', Time.now
		@closed, @close_scheduled, @streaming = false, false, false
		@conn.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK)
		post_init
		# attempt to read data from the request right away
		# after that we attach to the reactor (unless the connection was closed)		
		begin	
			data = @conn.sysread(CHUNK_SIZE)
			report_activity
			data_received(data)
		rescue Errno::EWOULDBLOCK, Errno::EAGAIN, Errno::EINTR
			# do nothing
		rescue EOFError
			@conn.close
		end
		unless @conn.closed?
			@reactor.attach(:read, @conn) do |conn, reactor|
				begin
					data = @conn.sysread(CHUNK_SIZE)
					report_activity
					data_received()
				rescue Errno::EWOULDBLOCK, Errno::EAGAIN, Errno::EINTR
					# do nothing
				rescue EOFError
					close(false)
				end
			end
		end
	end

	def post_init
	end

	def data_received(data)
	end
	
	def do_write
		begin
			buffer = @write_buffer.length > CHUNK_SIZE ? @write_buffer.slice(0, CHUNK_SIZE) : @write_buffer
			written = @conn.syswrite(buffer)
			if written == @write_buffer.length
				@write_buffer = ''
				@reactor.detach(:write, @conn)
				@conn.close if @close_scheduled
			else
				@write_buffer = buffer.slice!(written, buffer.length)
			end
			report_activity
		rescue Errno::EWOULDBLOCK, Errno::EAGAIN, Errno::EINTR
			# do nothing
		rescue EOFError
			close(false)
		end
	end

	def write(data)
		raise "Cannot write after scheduling a close" if @close_scheduled
		raise "Cannot write during a streaming process" if @streaming
		@write_buffer << data
		return if @reactor.attached?(:write, @conn)
		# attempt to write right away, but attach to reactor if not ready now
		do_write
		if @write_buffer.length > 0
			@reactor.attach(:write, @conn) do |conn, reactor|
				do_write				
			end
		else
			do_stream if @streaming
			close if @close_scheduled
		end
	end
	
	def empty?
		@write_buffer.empty?
	end

	def stream(options)
		raise "stream already active" if @streaming
		@streaming = true
		@streaming_options = options
	  do_stream if @write_buffer.empty?
	end

	def do_stream
		# remove the connection from the reactor
		# since we need to avoid any interference
		@reactor.detach(:write, @conn) 
		# we start the streaming operation in a new thread
		# should be a thread pool to make better use of resources
		Thread.new do
			# instead of trying to copy all at once
			# we chunk the response, this allows us to avoid
			# reaping the connection for really large files
			done = false
			while !done
				IO.copy_stream(*@streaming_options)
			end
			@reactor.next_tick do
				@streaming_options = nil
				@streaming = false
				close if @close_scheduled
			end			
		end
	end	

	def close(after_writing = true)
		return if @closed		
		if !after_writing || (@write_buffer.empty? && !@streaming)
			@closed = true
			@conn.close unless @conn.closed?
			@reactor.detach(:read, @conn)
			@reactor.detach(:write, @conn)
		else
			@close_scheduled = true
		end
	end
	
	def report_activity
		@last_active = Time.now
		@server.connections.delete(self.object_id)
		@server.connections[self.object_id] = self
	end

end
