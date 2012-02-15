_u = require 'underscore'
url = require('url')

module.exports = class Sockets
    DefaultOptions:
        source:         null
        min_digits:     6
        
    constructor: (options) ->
        @options = _u(_u({}).extend(@DefaultOptions)).extend( options || {} )
            
        @io = require("socket.io").listen @options.server
        @core = @options.core
        
        @sessions = {}
        
        _u(@core.streams).each (v,k) =>
            console.log 
            # register connection listener
            @io.of("/#{k}").on "connection", (sock) =>
                console.log "connection is ", sock.id
                console.log "stream is #{k}"

                @sessions[sock.id] ||= {
                    id:         sock.id
                    rewind:     v.rewind
                    socket:     sock
                    listener:   null
                    offset:     0
                }
                
                # add offset listener
                sock.on "offset", (i,fn) =>
                    # this might be called with a stream connection active, 
                    # or it might not.  we have to check
                    s = @sessions[sock.id]
                    if s.listener
                        s.listener.setOffset(i)
                        s.offset = s.listener._playHead
                    else
                        s.offset = s.rewind.checkOffset i
                
                    fn?(s.offset / s.rewind.framesPerSec)                        

                # send ready signal
                sock.emit "ready",
                    time:       new Date
                    buffered:   v.rewind.bufferedSecs()

                # set stream timecheck
                setInterval( =>
                    sock.emit "timecheck"
                        time:       new Date
                        buffered:   v.rewind.bufferedSecs()
                , 2000)
    
    #----------
            
    addListener: (req,res,stream) ->
        requrl = url.parse(req.url,true)
        
        if requrl.query.socket? && sess = @sessions[requrl.query.socket]
            listen = new Sockets.Listener sess,req,res,sess.rewind
            sess.listener = listen
            console.log "wired listener to session #{sess.id}"

    #----------
        
    class @Listener
        constructor: (session,req,res,rewind) ->
            @req = req
            @res = res
            @rewind = rewind

            # set our internal offset to be live by default
            @_offset = 1
            @_playHead = 1
            
            console.log "req is ", req.headers
            
            headers = 
                "Content-Type":         "audio/mpeg"
                "Connection":           "keep-alive"
                "Transfer-Encoding":    "identity"
                "Content-Range":        "bytes 0-*/*"
                "Accept-Ranges":        "none"

            # write out our headers
            res.writeHead 200, headers
            
            # and register to sending data...
            @rewind.addListener @

            @req.connection.on "close", =>
                # stop listening to stream
                @rewind.removeListener @  

        #----------

        writeFrame: (chunk) ->
            @res.write chunk

        #----------

        setOffset: (offset) ->
            @_playHead = @rewind.checkOffset offset
            @_offset = @rewind.burstFrom @_playHead, @