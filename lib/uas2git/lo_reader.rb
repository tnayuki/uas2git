module Uas2Git
  class LOReader
    def initialize(connection)
      @connection = connection
    end

    def open(stream, &block)
      @connection.transaction do
        begin
          @fd = @connection.lo_open(stream)

          r = yield self

        ensure
          @connection.lo_close(@fd)

          r
        end
      end
    end

    def read(size)
      @connection.lo_read(@fd, size)
    end
  end
end
