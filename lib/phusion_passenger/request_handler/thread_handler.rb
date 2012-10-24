#  Phusion Passenger - http://www.modrails.com/
#  Copyright (c) 2010-2012 Phusion
#
#  "Phusion Passenger" is a trademark of Hongli Lai & Ninh Bui.
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#  THE SOFTWARE.

require 'phusion_passenger/constants'
require 'phusion_passenger/debug_logging'
require 'phusion_passenger/message_channel'
require 'phusion_passenger/utils'
require 'phusion_passenger/utils/unseekable_socket'
require 'phusion_passenger/utils/robust_interruption'

module PhusionPassenger
class RequestHandler


# This class encapsulates the logic of a single RequestHandler thread.
class ThreadHandler
	include DebugLogging
	include Utils::RobustInterruption

	REQUEST_METHOD = 'REQUEST_METHOD'.freeze
	PING           = 'PING'.freeze
	PASSENGER_CONNECT_PASSWORD  = 'PASSENGER_CONNECT_PASSWORD'.freeze

	MAX_HEADER_SIZE = 128 * 1024

	OBJECT_SPACE_SUPPORTS_LIVE_OBJECTS      = ObjectSpace.respond_to?(:live_objects)
	OBJECT_SPACE_SUPPORTS_ALLOCATED_OBJECTS = ObjectSpace.respond_to?(:allocated_objects)
	OBJECT_SPACE_SUPPORTS_COUNT_OBJECTS     = ObjectSpace.respond_to?(:count_objects)
	GC_SUPPORTS_TIME        = GC.respond_to?(:time)
	GC_SUPPORTS_CLEAR_STATS = GC.respond_to?(:clear_stats)

	attr_reader :stats_mutex
	attr_reader :iterations
	attr_reader :processed_requests

	def initialize(request_handler, options = {})
		@request_handler   = request_handler
		@server_socket     = Utils.require_option(options, :server_socket)
		@socket_name       = Utils.require_option(options, :socket_name)
		@protocol          = Utils.require_option(options, :protocol)
		@app_group_name    = Utils.require_option(options, :app_group_name)
		Utils.install_options_as_ivars(self, options,
			:app,
			:analytics_logger,
			:connect_password
		)

		@stats_mutex = Mutex.new
		@iterations = 0
		@processed_requests = 0

		if @protocol == :session
			metaclass = class << self; self; end
			metaclass.class_eval do
				alias parse_request parse_session_request
			end
		elsif @protocol == :http
			metaclass = class << self; self; end
			metaclass.class_eval do
				alias parse_request parse_http_request
			end
		else
			raise ArgumentError, "Unknown protocol specified"
		end
	end

	def install
		Thread.current[:handler] = self
		install_robust_interruption
	end

	def main_loop
		socket_wrapper = Utils::UnseekableSocket.new
		channel        = MessageChannel.new
		buffer         = ''
		
		begin
			disable_interruptions do
				while !Utils::RobustInterruption.interrupted?
					accept_and_process_next_request(socket_wrapper, channel, buffer)
				end
			end
		rescue Utils::RobustInterruption::Interrupted
			# Do nothing.
		end
		debug("Thread handler main loop exited normally")
	end

	def idle?
		@stats_mutex.synchronize { return !@processing }
	end

private
	def accept_and_process_next_request(socket_wrapper, channel, buffer)
		@stats_mutex.synchronize { @iterations += 1 }
		connection = enable_interruptions { socket_wrapper.wrap(@server_socket.accept) }
		@stats_mutex.synchronize { @processing = true }
		trace(3, "Accepted new request on socket #{@socket_name}")
		channel.io = connection
		if headers = parse_request(connection, channel, buffer)
			prepare_request(headers)
			begin
				if headers[REQUEST_METHOD] == PING
					process_ping(headers, connection)
				else
					process_request(headers, connection, @protocol == :http)
				end
			rescue Exception
				has_error = true
				raise
			ensure
				finalize_request(headers, has_error)
				trace(3, "Request done.")
			end
		else
			trace(2, "No headers parsed; disconnecting client.")
		end
	rescue => e
		if socket_wrapper.source_of_exception?(e)
			# EPIPE is harmless, it just means that the client closed the connection.
			# Other errors might indicate a problem so we print them, but they're
			# probably not bad enough to warrant stopping the request handler.
			if !e.is_a?(Errno::EPIPE)
				print_exception("Passenger RequestHandler's client socket", e)
			end
			return true
		else
			if @analytics_logger && headers && headers[PASSENGER_TXN_ID]
				log_analytics_exception(headers, e)
			end
			raise e
		end
	ensure
		# The 'close_write' here prevents forked child
		# processes from unintentionally keeping the
		# connection open.
		if connection && !connection.closed?
			begin
				connection.close_write
			rescue SystemCallError
			end
			begin
				connection.close
			rescue SystemCallError
			end
		end
		@stats_mutex.synchronize do
			@processed_requests += 1
			@processing = false
		end
	end

	def parse_session_request(connection, channel, buffer)
		headers_data = channel.read_scalar(buffer, MAX_HEADER_SIZE)
		if headers_data.nil?
			return
		end
		headers = Utils.split_by_null_into_hash(headers_data)
		if @connect_password && headers[PASSENGER_CONNECT_PASSWORD] != @connect_password
			warn "*** Passenger RequestHandler warning: " <<
				"someone tried to connect with an invalid connect password."
			return
		else
			return headers
		end
	rescue SecurityError => e
		warn("*** Passenger RequestHandler warning: " <<
			"HTTP header size exceeded maximum.")
		return
	end
	
	# Like parse_session_request, but parses an HTTP request. This is a very minimalistic
	# HTTP parser and is not intended to be complete, fast or secure, since the HTTP server
	# socket is intended to be used for debugging purposes only.
	def parse_http_request(connection, channel, buffer)
		headers = {}
		
		data = ""
		while data !~ /\r\n\r\n/ && data.size < MAX_HEADER_SIZE
			data << connection.readpartial(16 * 1024)
		end
		if data.size >= MAX_HEADER_SIZE
			warn("*** Passenger RequestHandler warning: " <<
				"HTTP header size exceeded maximum.")
			return
		end
		
		data.gsub!(/\r\n\r\n.*/, '')
		data.split("\r\n").each_with_index do |line, i|
			if i == 0
				# GET / HTTP/1.1
				line =~ /^([A-Za-z]+) (.+?) (HTTP\/\d\.\d)$/
				request_method = $1
				request_uri    = $2
				protocol       = $3
				path_info, query_string    = request_uri.split("?", 2)
				headers[REQUEST_METHOD]    = request_method
				headers["REQUEST_URI"]     = request_uri
				headers["QUERY_STRING"]    = query_string || ""
				headers["SCRIPT_NAME"]     = ""
				headers["PATH_INFO"]       = path_info
				headers["SERVER_NAME"]     = "127.0.0.1"
				headers["SERVER_PORT"]     = connection.addr[1].to_s
				headers["SERVER_PROTOCOL"] = protocol
			else
				header, value = line.split(/\s*:\s*/, 2)
				header.upcase!            # "Foo-Bar" => "FOO-BAR"
				header.gsub!("-", "_")    #           => "FOO_BAR"
				if header == "CONTENT_LENGTH" || header == "CONTENT_TYPE"
					headers[header] = value
				else
					headers["HTTP_#{header}"] = value
				end
			end
		end
		
		if @connect_password && headers["HTTP_X_PASSENGER_CONNECT_PASSWORD"] != @connect_password
			warn "*** Passenger RequestHandler warning: " <<
				"someone tried to connect with an invalid connect password."
			return
		else
			return headers
		end
	rescue EOFError
		return
	end

	def process_ping(env, connection)
		connection.write("pong")
	end

#	def process_request(env, connection, full_http_response)
#		raise NotImplementedError, "Override with your own implementation!"
#	end

	def prepare_request(headers)
		if @analytics_logger && headers[PASSENGER_TXN_ID]
			txn_id = headers[PASSENGER_TXN_ID]
			union_station_key = headers[PASSENGER_UNION_STATION_KEY]
			log = @analytics_logger.continue_transaction(txn_id,
				@app_group_name,
				:requests, union_station_key)
			headers[PASSENGER_ANALYTICS_WEB_LOG] = log
			Thread.current[PASSENGER_ANALYTICS_WEB_LOG] = log
			Thread.current[PASSENGER_TXN_ID] = txn_id
			Thread.current[PASSENGER_UNION_STATION_KEY] = union_station_key
			if OBJECT_SPACE_SUPPORTS_LIVE_OBJECTS
				log.message("Initial objects on heap: #{ObjectSpace.live_objects}")
			end
			if OBJECT_SPACE_SUPPORTS_ALLOCATED_OBJECTS
				log.message("Initial objects allocated so far: #{ObjectSpace.allocated_objects}")
			elsif OBJECT_SPACE_SUPPORTS_COUNT_OBJECTS
				count = ObjectSpace.count_objects
				log.message("Initial objects allocated so far: #{count[:TOTAL] - count[:FREE]}")
			end
			if GC_SUPPORTS_TIME
				log.message("Initial GC time: #{GC.time}")
			end
			log.begin_measure("app request handler processing")
		end
		
		#################
	end
	
	def finalize_request(headers, has_error)
		log = headers[PASSENGER_ANALYTICS_WEB_LOG]
		if log && !log.closed?
			exception_occurred = false
			begin
				log.end_measure("app request handler processing", has_error)
				if OBJECT_SPACE_SUPPORTS_LIVE_OBJECTS
					log.message("Final objects on heap: #{ObjectSpace.live_objects}")
				end
				if OBJECT_SPACE_SUPPORTS_ALLOCATED_OBJECTS
					log.message("Final objects allocated so far: #{ObjectSpace.allocated_objects}")
				elsif OBJECT_SPACE_SUPPORTS_COUNT_OBJECTS
					count = ObjectSpace.count_objects
					log.message("Final objects allocated so far: #{count[:TOTAL] - count[:FREE]}")
				end
				if GC_SUPPORTS_TIME
					log.message("Final GC time: #{GC.time}")
				end
				if GC_SUPPORTS_CLEAR_STATS
					# Clear statistics to void integer wraps.
					GC.clear_stats
				end
				Thread.current[PASSENGER_ANALYTICS_WEB_LOG] = nil
			rescue Exception
				# Maybe this exception was raised while communicating
				# with the logging agent. If that is the case then
				# log.close may also raise an exception, but we're only
				# interested in the original exception. So if this
				# situation occurs we must ignore any exceptions raised
				# by log.close.
				exception_occurred = true
				raise
			ensure
				# It is important that the following call receives an ACK
				# from the logging agent and that we don't close the socket
				# connection until the ACK has been received, otherwise
				# the helper agent may close the transaction before this
				# process's openTransaction command is processed.
				begin
					log.close
				rescue
					raise if !exception_occurred
				end
			end
		end
		
		#################
	end
	
	def log_analytics_exception(env, exception)
		log = @analytics_logger.new_transaction(
			@app_group_name,
			:exceptions,
			env[PASSENGER_UNION_STATION_KEY])
		begin
			request_txn_id = env[PASSENGER_TXN_ID]
			message = exception.message
			message = exception.to_s if message.empty?
			message = [message].pack('m')
			message.gsub!("\n", "")
			backtrace_string = [exception.backtrace.join("\n")].pack('m')
			backtrace_string.gsub!("\n", "")

			log.message("Request transaction ID: #{request_txn_id}")
			log.message("Message: #{message}")
			log.message("Class: #{exception.class.name}")
			log.message("Backtrace: #{backtrace_string}")
		ensure
			log.close
		end
	end
end


end # class RequestHandler
end # module PhusionPassenger
