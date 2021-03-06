nconf       = require "nconf"
_u          = require "underscore"
nodemailer  = require "nodemailer"

ALERT_TYPES = 
    sourceless:
        description:    "A monitored stream has lost its only source connection."
        wait_for:       30
        
    disconnected:
        description:    "A slave server has lost its connection to the master server."
        wait_for:       30

# Alerts module is responsible for understanding how long we should wait 
# before saying something about alert conditions.  Code calls the alert 
# class with a code, a key and a state.  

module.exports = class Alerts extends require("events").EventEmitter
    constructor: (@opts) ->
        @logger = @opts.logger
        
        @email = new Alerts.Email @, nconf.get("alerts:email") if nconf.get("alerts:email")

        @_states = {}
        
    #----------
    
    update: (code,key,active) ->
        # make sure we know what this is...
        if !ALERT_TYPES[code]
            console.log "Unknown alert type sent: #{code} / #{key}"
            return false
            
        if !@_states[ code ]
            @_states[ code ] = {}
            
        # are we setting or unsetting?
        if active
            if s = @_states[ code ][ key ]
                # update our timestamp
                s.last_seen_at = new Date
                
                # make sure there isn't an all-clear waiting to fire
                clearTimeout s.c_timeout if s.c_timeout
                delete s.c_timeout              
                
            else
                # setting for the first time...
                s = @_states[ code ][ key ] = 
                    code:           code
                    key:            key
                    triggered_at:   new Date
                    last_seen_at:   new Date
                    alert_sent:     false
                    a_timeout:      null
                    c_timeout:      null

            # -- should we set a timeout for triggering an alarm? -- #
            
            if !s.alert_sent && !s.a_timeout
                s.a_timeout = setTimeout =>
                    @_fireAlert(s)
                , ALERT_TYPES[ code ].wait_for * 1000
                
        else
            # clear an alert state if it is set
            if s = @_states[ code ][ key ]
                # -- is there an alert timeout set? -- #
                clearTimeout s.a_timeout if s.a_timeout
                delete s.a_timeout              
                
                if s.alert_sent && !s.c_timeout
                    # we had sent an alert, so send a note that the alert has cleared
                    s.c_timeout = setTimeout =>
                        @_fireAllClear(s)
                    , ALERT_TYPES[ code ].wait_for * 1000
                else
                    # no harm, no foul
            else
                # they've always been good...
    
    #----------
            
    _fireAlert: (obj) ->
        console.log "alert", "#{obj.code}:#{obj.key}", obj
        
        alert = 
            code:           obj.code
            key:            obj.key
            triggered_at:   obj.triggered_at
            description:    ALERT_TYPES[ obj.code ].description
        
        @logger.alert "Alert: #{obj.key} : #{ alert.description }", alert
        @emit "alert", alert
        
        # mark our alert as sent
        obj.alert_sent = true
        
    #----------
        
    _fireAllClear: (obj) ->
        console.log "all_clear", "#{obj.code}:#{obj.key}", obj
        
        alert = 
            code:           obj.code
            key:            obj.key
            triggered_at:   obj.triggered_at
            last_seen_at:   obj.last_seen_at
            description:    ALERT_TYPES[ obj.code ].description
        
        @logger.alert "Alert Cleared: #{obj.key} : #{ alert.description }", alert
        @emit "alert_cleared", alert
        
        # we need to delete the alert now that it has been cleared. If the 
        # condition returns, it will be as a new event
        delete @_states[ obj.code ][ obj.key ]
    
    #----------
        
    class @Email
        constructor: (@alerts,@opts) ->
            # -- set up the transport -- #
            
            @transport = nodemailer.createTransport(@opts.mailer_type,@opts.mailer_options)
            
            # -- register our listener -- #
            
            @alerts.on "alert", (msg) => @_sendAlert(msg)
            @alerts.on "alert_cleared", (msg) => @_sendAllClear(msg)
        
        #----------
            
        _sendAlert: (msg) ->
            email = _u.extend {}, @opts.email_options, 
                subject: "[StreamMachine/#{msg.key}] #{msg.code} Alert"
                generateTextFromHTML: true
                html:   """
                        <p>StreamMachine has detected an alert condition of <b>#{msg.code}</b> for <b>#{msg.key}</b>.</p>
                        
                        <p>#{msg.description}</p>
                        
                        <p>Condition was first detected at <b>#{msg.triggered_at}</b>.</p>
                        """
                        
            @transport.sendMail email, (err,resp) =>
                if err
                    @alerts.logger.error "Error sending alert email: #{err}", error:err
                    return false
                    
                @alerts.logger.debug "Alert email sent to #{email.to}.", code:msg.code, key:msg.key
        
        #----------
            
        _sendAllClear: (msg) ->
            email = _u.extend {}, @opts.email_options, 
                subject: "[StreamMachine/#{msg.key}] #{msg.code} Cleared"
                generateTextFromHTML: true
                html:   """
                        <p>StreamMachine has cleared an alert condition of <b>#{msg.code}</b> for <b>#{msg.key}</b>.</p>
                        
                        <p>#{msg.description}</p>
                        
                        <p>Condition was first detected at <b>#{msg.triggered_at}</b>.</p>
                        
                        <p>Condition was last seen at <b>#{msg.last_seen_at}</b>.</p>
                        """
                        
            @transport.sendMail email, (err,resp) =>
                if err
                    @alerts.logger.error "Error sending all clear email: #{err}", error:err
                    return false
                    
                @alerts.logger.debug "All clear email sent to #{email.to}.", code:msg.code, key:msg.key
            
        #----------