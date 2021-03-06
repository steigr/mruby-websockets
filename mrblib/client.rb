module WebSocket
  def self.create_key
    B64.encode(RandomBytes.buf(16)).chomp!
  end

  class WsConnection
    def initialize(host, port, path, *args)
      @host = host
      @port = port
      @path = path
      @socket = TCPSocket.new host, port
    end

    def recv(timeout)
      if @msgs.empty?
        if @client.want_read?
          @socket_pi.events = Poll::In
          @client.recv if @poll.wait(timeout)
        end
      end
      @msgs.shift
    ensure
      @socket_pi.events = Poll::Out
      while @client.want_write?
        @client.send if @poll.wait(timeout)
      end
    end

    def send(msg, opcode, timeout)
      if opcode
        @client.queue_msg(msg, opcode)
      else
        @client.queue_msg(msg)
      end
      @socket_pi.events = Poll::Out
      while @client.want_write?
        @client.send if @poll.wait(timeout)
      end
      self
    end

    def close(status_code, reason, timeout)
      if reason
        @client.queue_close(status_code, reason)
      else
        @client.queue_close(status_code)
      end
      while @client.want_write?||@client.want_read?
        @socket_pi.events = 0
        @socket_pi.events |= Poll::In  if @client.want_read?
        @socket_pi.events |= Poll::Out if @client.want_write?
        if @poll.wait(timeout)
          @client.send if @socket_pi.writable?
          @client.recv if @socket_pi.readable?
        end
      end
      @msgs.dup
    ensure
      @socket.close
      @msgs.clear
    end

    def setup
      http_handshake
      make_nonblock
      setup_ws
      setup_poller
    rescue => e
      @socket.close
      raise e
    end

    def socket
      http_handshake unless @http_handshake_successful
      @socket
    end

    def msgs
      @msgs ||= []
    end

    private

    def http_handshake
      key = WebSocket.create_key
      @socket.write("GET #{@path} HTTP/1.1\r\nHost: #{@host}:#{@port}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Protocol: binary\r\n\r\n")
      buf  = @socket.readline
      buf << @socket.readline until buf[-4..-1] == "\r\n\r\n"
      puts buf.inspect
      phr = Phr.new
      loop do
        ret = phr.parse_response(buf)
        case ret
        when Fixnum
          break
        when :incomplete
          buf << @socket.readline
        when :parser_error
          raise Error, "HTTP Parser error"
        end
      end
      headers = phr.headers.to_h
      unless WebSocket.create_accept(key).securecmp(headers.fetch('sec-websocket-accept'))
        @http_handshake_successful = false
        raise Error, "Handshake failure"
      end
      @http_handshake_successful ||= true
    end

    def make_nonblock
      @socket._setnonblock(true)
    end

    def setup_ws
      @callbacks = Wslay::Event::Callbacks.new
      @callbacks.recv_callback {|buf, len| @socket.read len}
      @callbacks.send_callback {|buf| @socket.write buf}
      @msgs = []
      @callbacks.on_msg_recv_callback {|msg| @msgs << msg}
      @client = Wslay::Event::Context::Client.new @callbacks
    end

    def setup_poller
      @poll = Poll.new
      @socket_pi = @poll.add(@socket)
    end
  end

  class WssConnection < WsConnection
    def initialize(host, port, path, *args)
      @host = host
      @port = port
      @path = path
      @tcp_socket = TCPSocket.new host, port
      @socket = TLS.new(@tcp_socket,*args)
    end

    private
    def make_nonblock
      @tcp_socket._setnonblock(true)
    end

    def setup_ws
      @callbacks = Wslay::Event::Callbacks.new
      @callbacks.recv_callback do |buf, len|
        ret = -1
        begin
          ret = @socket.read len
        rescue RuntimeError
          raise Errno::EWOULDBLOCK
        end
        ret
      end
      @callbacks.send_callback do |buf|
        ret = -1
        begin
          ret = @socket.write buf
        rescue RuntimeError
          raise Errno::EWOULDBLOCK
        end
        ret
      end
      @msgs = []
      @callbacks.on_msg_recv_callback {|msg| @msgs << msg}
      @client = Wslay::Event::Context::Client.new @callbacks
    end


    def setup_poller
      @poll = Poll.new
      @socket_pi = @poll.add(@tcp_socket)
    end
  end

  class Client
    def initialize(proto, host, port, path, *args)
      case proto
      when :ws
        @connection = WsConnection.new(host, port, path, *args)
      when :wss
        @connection = WssConnection.new(host, port, path, *args)
      end
      @connection.setup
    end

    def recv(timeout = -1)
      @connection.recv(timeout)
    end

    def send(msg, opcode = nil, timeout = -1)
      @connection.send(msg, opcode, timeout)
      self
    end

    alias :<< :send

    def close(status_code = :normal_closure, reason = nil, timeout = -1)
      @connection.close(status_code, reason, timeout)
    end

    def socket
      @connection.socket
    end

    def msgs
      @connection.msgs
    end
  end
end
