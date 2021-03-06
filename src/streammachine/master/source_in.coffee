_u = require "underscore"
net = require "net"
express = require "express"

module.exports = class SourceIn extends require("events").EventEmitter
    constructor: (opts) ->
        @core = opts.core
        
        @log = @core.log.child mode:"sourcein"
        
        # grab our listening port
        @port = opts.port
        
        # create our server
        
        @server = net.createServer (c) => @_connection(c)
        
    listen: (spec=@port) ->
        #@core.log.debug "SourceIn listening on ", spec:spec
        @server.listen spec
        
    _connection: (sock) => 
        @log.debug "Incoming source attempt."
        # -- incoming data -- #
        
        parser = new SourceIn.IcyParser SourceIn.IcyParser.REQUEST
        parser.socket = sock
        parser.incoming = null
        
        sock.ondata = (d,start,end) =>
            parser.execute d, start, end - start
            
        parser.on "headersComplete", (headers) =>
            if parser.info.protocol == "ICE" || parser.info.method == "SOURCE"
                @log.debug "ICY SOURCE attempt.", url:parser.info.url
                @_trySource sock, parser.info
                
                # get out of the way
                sock.ondata = null
                
            # TODO: Need to add support for the shoutcast metadata admin URL
                
                        
    _trySource: (sock,info) =>
        # source request... is the endpoint one that we recognize?
        if m = ///^/(#{_u(@core.streams).keys().join("|")})///.exec info.url
            stream = @core.streams[ m[1] ]

            # cool, now make sure we have the headers we need

            # first, make sure the authorization header contains the right password
            @log.debug "Trying to authenticate ICY source for #{stream.key}"
            if info.headers.authorization && @_authorize(stream,info.headers.authorization)
                sock.write "HTTP/1.0 200 OK\n\n"
                @log.debug "ICY source authenticated for #{stream.key}"

                # now create a new source
                source = new (require "../sources/icecast") stream, sock, info.headers
                stream.addSource source
            else
                @log.debug "ICY source failed to authenticate for #{stream.key}."
                sock.write "HTTP/1.0 401 Unauthorized\r\n"
                sock.end "Invalid source or password.\r\n"

        else
            @log.debug "ICY source attempted to connect to bad URL.", url:info.url
            
            sock.write "HTTP/1.0 401 Unauthorized\r\n"
            sock.end "Invalid source or password.\r\n"
            
    _tmp: ->
        if ///^/admin/metadata///.match req.url
            res.writeHead 200, headers
            res.end "OK"
            
        else
            res.writeHead 400, headers
            res.end "Invalid method #{res.method}."
    
    #----------
            
    _authorize: (stream,header) ->
        # split the auth type from the value
        [type,value] = header.split " "
        
        if type.toLowerCase() == "basic"
            value = new Buffer(value, 'base64').toString('ascii')
            [user,pass] = value.split ":"
            
            if pass == stream.opts.source_password
                true
            else
                false
        else
            false
    
    #----------
            
    class @IcyParser extends require("events").EventEmitter
        constructor: (type) ->
            @["INIT_"+type]()
    
        @REQUEST:    "REQUEST"
        @RESPONSE:   "RESPONSE" 

        reinitialize: @

        execute: (@chunk,@offset,length) ->
            @start = @offset
            @end = @offset + length
    
            while @offset < @end
                @[@state]()
                @offset++;
                
            true
        
        INIT_REQUEST: ->
            @state = "REQUEST_LINE"
            @lineState = "DATA"
            @info = headers:{}
    
        consumeLine: ->
            @captureStart = @offset if !@captureStart?
    
            byte = @chunk[@offset]
            if byte == 0x0d && @lineState == "DATA" # \r
                @captureEnd = @offset
                @lineState = "ENDING"
                return
        
            if @lineState == "ENDING"
                @lineState = "DATA"
                return if byte != 0x0a
        
                line = @chunk.toString "ascii", @captureStart, @captureEnd
        
                @captureStart = undefined
                @captureEnd = undefined
        
                return line
        
        requestExp: /^([A-Z]+) (.*) (ICE|HTTP)\/(1).(0|1)$/;
    
        REQUEST_LINE: ->
            line = @consumeLine()
    
            return if !line?
        
            match = @requestExp.exec line
    
            [@info.method,@info.url,@info.protocol,@info.versionMajor,@info.versionMinor] = match[1..5]
            
            @info.request_offset = @offset
            @info.request_line = line
    
            @state = "HEADER"

        headerExp: /^([^:]+): *(.*)$/

        HEADER: ->
            line = @consumeLine()
    
            return if !line?
    
            if line
                match = @headerExp.exec line
                @info.headers[match[1].toLowerCase()] = match[2]
            else
                @emit "headersComplete", @info.headers
                @state = "BODY"