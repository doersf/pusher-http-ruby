require 'signature'
require 'digest/md5'
require 'oj'


module Pusher
  class Request
    attr_reader :body, :params

    def initialize(client, verb, uri, params, body = nil)
      @client, @verb, @uri = client, verb, uri
      @head = {}

      @body = body
      if body
        params[:body_md5] = Digest::MD5.hexdigest(body)
        @head['Content-Type'] = 'application/json'
      end

      request = Signature::Request.new(verb.to_s.upcase, uri.path, params)
      request.sign(client.authentication_token)
      @params = request.signed_params
    end

    def send_sync
      http = @client.sync_http_client

      begin

        response = http.request(@verb, @uri, @head, {:query => @params, :data => @body})
        Pusher.logger.debug("Sent: #{@verb} #{@uri} #{@params} #{@body} #{@head}")

      rescue Exception => e
        raise e
      end

      body = response.body ? response.body.chomp : nil

      return handle_response(response.status.to_i, body)
    end

    def send_async
      if defined?(EventMachine) && EventMachine.reactor_running?
        http_client = @client.em_http_client(@uri)
        df = EM::DefaultDeferrable.new

        http = case @verb
        when :post
          http_client.post({
            :query => @params, :body => @body, :head => @head
          })

                 puts "Query: #{@params}, Body: #{@body}, Head: #{@head}"
        when :get
          http_client.get({
            :query => @params, :head => @head
          })
        else
          raise "Unsupported verb"
        end
        http.callback {
          puts "success"
          begin
            df.succeed(handle_response(http.response_header.status, http.response.chomp))
          rescue => e
            df.fail(e)
          end
        }
        http.errback { |e|
          message = "Network error connecting to pusher (#{http.error})"
          Pusher.logger.debug(message)
          df.fail(Error.new(message))
        }

        return df
      else

        raise "No EventMachine Reactor found. Aborting asynchronous call."

      end
    end

    private

    def handle_response(status_code, body)
      case status_code
      when 200
        return symbolize_first_level(Oj.load(body, mode: :compat))
      when 202
        return true
      when 400
        raise Error, "Bad request: #{body}"
      when 401
        raise AuthenticationError, body
      when 404
        raise Error, "404 Not found (#{@uri.path})"
      when 407
        raise Error, "Proxy Authentication Required"
      else
        raise Error, "Unknown error (status code #{status_code}): #{body}"
      end
    end

    def symbolize_first_level(hash)
      hash.inject({}) do |result, (key, value)|
        result[key.to_sym] = value
        result
      end
    end
  end
end
