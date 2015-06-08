mongoose = require "mongoose"
ActiveMatch = require "./model/activeMatch"
User        = require "./model/user"
League      = require "./model/league"
TeamSpeakClient = require "node-teamspeak"
util        = require "util"
_  = require "lodash"

typeIsArray = ( value ) ->
  value and
    typeof value is 'object' and
    value instanceof Array and
    typeof value.length is 'number' and
    typeof value.splice is 'function' and
    not ( value.propertyIsEnumerable 'length' )

log = console.log

if process.env.IGNORE_ERRORS?
  process.on 'uncaughtException', (err)->
    console.log "Uncaught exception! #{err}"


console.log "Setting up our database connection..."
if !process.env.MONGODB_URL?
  console.log "MONGODB_URL env variable required!"
  return

tsIp = process.env.TEAMSPEAK_IP
if !tsIp?
  console.log "TEAMSPEAK_IP env variable required!"
  return

tsPort = process.env.TEAMSPEAK_PORT
if !tsPort?
  parts = tsIp.split ":"
  if parts? && parts.length is 2
    tsPort = parseInt parts[1]
    tsIp = parts[0]
  else
    console.log "Using default teamspeak_port"
    tsPort = 10011

tsUser = process.env.TEAMSPEAK_USER
if !tsUser?
  console.log "TEAMSPEAK_USER env variable required!"
  return

tsPassword = process.env.TEAMSPEAK_PASSWORD
if !tsPassword?
  console.log "TEAMSPEAK_PASSWORD env variable required!"
  return

mongoose.connect(process.env.MONGODB_URL)

User.update {}, {$set: {tsonline: false}}, {multi: true}, (err)->
  if err?
    console.log "Unable to set tsonline to false on everyone, #{err}"

defaultChannels =
  "Lobby":
    channel_name: "Lobby"
    channel_codec_quality: 10
    #channel_flag_default: 1
    channel_flag_permanent: 1
    channel_description: "General chat."
  "[spacer2]":
    channel_name: "[spacer2]"
    channel_flag_permanent: 1
    channel_max_clients: 0
    channel_flag_maxclients_unlimited: 0
  "Lounge 1":
    channel_name: "Lounge 1"
    channel_codec_quality: 10
    channel_flag_permanent: 1
    channel_description: "Lounge 1"
  "Lounge 2":
    channel_name: "Lounge 2"
    channel_codec_quality: 10
    channel_flag_permanent: 1
    channel_description: "Lounge 2"
  "Lounge 3":
    channel_name: "Lounge 3"
    channel_codec_quality: 10
    channel_flag_permanent: 1
    channel_description: "Lounge 3"
  "[spacer1]":
    channel_name: "[spacer1]"
    channel_flag_permanent: 1
    channel_max_clients: 0
    channel_flag_maxclients_unlimited: 0
  "AFK":
    channel_name: "AFK"
    channel_codec_quality: 1
    channel_flag_permanent: 1
    channel_forced_silence: 1
    channel_needed_talk_power: 99999
  "Unknown":
    channel_name: "Unknown"
    channel_codec_quality: 1
    channel_description: "To verify your identity, follow these steps:\n    1. Left click your name at the top right of the FPL client.\n    2. Click \"Teamspeak Info\".\n    3. Copy the token in the window, and paste it into the text chat with the user \"FPL Server\" who will send you a message."
    channel_flag_permanent: 1
    channel_forced_silence: 1
    channel_needed_talk_power: 99999
    channel_password: "youcantjointhisskrub"
  "Bounce":
    channel_name: "Bounce"
    channel_codec_quality: 1
    channel_description: "This is a temporary channel, the bot should move you out immediately."
    channel_flag_permanent: 1
    channel_flag_default: 1
  "Lobby":
    channel_name: "Lobby"
    channel_codec_quality: 10
    #channel_flag_default: 1
    channel_flag_permanent: 1
    channel_description: "General chat."
  "[spacer0]":
    channel_name: "[spacer0]"
    channel_flag_permanent: 1
    channel_max_clients: 0
    channel_flag_maxclients_unlimited: 0
  "[spacer3]":
    channel_name: "[spacer3]"
    channel_flag_permanent: 1
    channel_max_clients: 0
    channel_flag_maxclients_unlimited: 0

serverGroups = {}
cl = null
updateInterval = null
cid = 0
me = null
connected = false
clientCache = {}
userCache   = {}
lastCurrentServerChannels = {}
checkedUids = []
messagedUids = []
onlineUsers = []
lastClients = null
lastLeagues = null

moveClientToHome = (client, currentServerChannels)->
  user = userCache[client.client_unique_identifier]
  if user? and user.vouch.leagues.length > 0 and lastLeagues?
    league = _.findWhere lastLeagues, {_id: user.vouch.leagues[0]}
    if league?
      chan = currentServerChannels[league.Name]
      if chan? and chan.cid?
        cl.send 'clientmove', {cid: chan.cid, clid: client.clid}, (err)->
          if err?
            console.log "Can't move client to his home, #{err}"
      else
        console.log "Unable to move client home, channel #{league.Name} not found."
    else
      console.log "Unable to move client home, league #{user.profile.leagues[0]} not found."
  else
    console.log "Unable to move user #{client.clid} home, user = #{util.inspect user} client = #{util.inspect client}"

initServerGroups = (cb)->
  cl.send 'servergrouplist', (err, resp)->
    if err?
      log "error fetching server group list! #{err}"
    else
      if resp?
        resp = [resp] unless typeIsArray resp
        for group in resp
          continue if group.type != 1
          serverGroups[parseInt(group.sgid)] = group.name
          console.log "#{group.sgid} = #{group.name}"
      else
        log "no server group response! this will be broken..."
    cb()

initNotify = (cb)->
  cl.send 'servernotifyregister', {event: "textprivate", id: 0}, (err)->
    if err?
      log "error registering text message notify! #{err}"
    cb()

initClient = ->
  cl = new TeamSpeakClient(tsIp, tsPort)
  cl.on "connect", ->
    connected = true
    cid++
    log "connected to the server"
    cl.send 'login', {
      client_login_name: tsUser
      client_login_password: tsPassword
    }, (err, response, rawResponse) ->
      cl.send 'use', { sid: 1 }, (err, response, rawResponse) ->
        if err?
          log "unable to select server, #{err}"
          return
        cl.send 'instanceedit', {serverinstance_serverquery_flood_commands: 100}, (err)->
          log "error changing query flood limit, #{util.inspect err}" if err?
          initServerGroups ->
            initNotify ->
              cl.send 'whoami', (err, resp)->
                if err?
                  log "error checking whoami!"
                  log err
                  return
                me = resp
                cl.send 'clientupdate', {clid: me.client_id, client_nickname: "FPL Server"}, (err)->
                  if err?
                    log "unable to change nickname, #{util.inspect err}"
                  log "ready, starting update loop..."
                  cid++
                  updateTeamspeak(cid)
  cl.on "error", (err)->
    log "socket error, #{err}"
  cl.on "textmessage", (msg)->
    return if msg.targetmode isnt 1 or msg.invokerid is me.client_id
    log "CHAT #{msg.invokername}: #{msg.msg}"
    cl.send 'clientinfo', {clid: msg.invokerid}, (err, client)->
      if err?
        log "can't lookup client, #{util.inspect err}"
        return
      if !client?
        log "no client for #{msg.invokerid}"
        return

      client.clid = msg.invokerid

      return moveClientToHome(client, lastCurrentServerChannels) if msg.msg is "moveme"

      uid = client.client_unique_identifier
      User.findOne {tsonetimeid: msg.msg.trim()}, (err, usr)->
        if err?
          log "unable to lookup tsonetimeid #{msg.msg}, #{util.inspect err}"
          return
        if usr?
          cl.send 'sendtextmessage', {targetmode: 1, target: msg.invokerid, msg: "Welcome, #{usr.profile.name}!"}
          cl.send 'clientedit', {clid: msg.invokerid, client_description: usr.profile.name}, (err)->
            if err?
              log "Unable to edit client #{client.cid}, #{util.inspect err}"
          user = userCache[uid] = usr.toObject()
          user.nextUpdate = new Date().getTime()+300000 #5 minutes
          user.tsuniqueids = user.tsuniqueids || [uid]
          user.tsuniqueids.push uid if uid not in user.tsuniqueids
          User.update {_id: usr._id}, {$set: {tsuniqueids: user.tsuniqueids, tsonetimeid: null}}, (err)->
            if err?
              log "unable to save tsuniqueid, #{err}"
        else
          cl.send 'sendtextmessage', {targetmode: 1, target: msg.invokerid, msg: "Your message, #{msg.msg}, isn't a valid token. Please try again."}

  cl.on "close", (err)->
    log "connection closed, reconnecting in 10 sec"
    connected = false
    if updateInterval?
      clearInterval updateInterval
      updateInterval = null
    setTimeout ->
      initClient()
    , 10000

currentServerChannels = {}
updateTeamspeak = (myid)->
  if myid != cid or !connected
    log "terminating old update loop #{myid}"
    return

  currentChannels = {}
  lastCurrentServerChannels = currentServerChannels
  currentServerChannels = {}
  pend = cl.getPending()
  updcalled = false
  onlineUsersNow = []

  nextUpdate = ->
    return if npdcalled
    npdcalled = true
    setTimeout ->
      updateTeamspeak(myid)
    , 2000

  if pend.length > 0
    log "commands still pending, deferring update"
    nextUpdate()
    return

  cl.send 'channellist', (err, resp)->
    if err?
      log "error fetching client list, #{util.inspect err}"
      return nextUpdate()
    for chan in resp
      currentServerChannels[chan.channel_name] = chan
      echan = defaultChannels[chan.channel_name]
      if echan?
        echan.cid = chan.cid
        echan.pid = chan.pid

    League.find {}, (err, leagues)->
      if err?
        log "error finding active leagues, #{util.inspect err}"
        return nextUpdate()

      lastLeagues = leagues

      leagues.forEach (league)->
        lid = league._id
        rchan = league.Name
        if !league.Archived
          exist = currentServerChannels[rchan]
          if exist?
            currentChannels[rchan] = exist
          else
            currentChannels[rchan] =
              channel_name: rchan
              channel_codec_quality: 10
              channel_description: "Lobby for league #{league.Name}."
              channel_flag_permanent: 1

      ActiveMatch.find {}, (err, matches)->
        if err?
          log "error fetching active matches, #{util.inspect err}"
          return nextUpdate()
        matches.forEach (match)->
          mid = match.Details.MatchId || 0
          rchann = ""
          if match.Info.MatchType == 0
            capt = _.findWhere match.Details.Players, {SID: match.Info.Owner}
            rchann = "#{capt.Name}'s Startgame"
          else if match.Info.MatchType == 2
            return
          else if match.Info.MatchType == 1
            capts = _.filter match.Details.Players, (plyr)-> plyr.IsCaptain
            rchann = "#{capts[0].Name} vs. #{capts[1].Name}"

          schan = currentServerChannels[rchann]
          if schan?
            currentChannels[rchann] = schan
            subs = _.filter _.values(currentServerChannels), (chan)-> chan.pid is schan.cid
            for sub in subs
              currentChannels[sub.channel_name] = sub
          else
            currentChannels[rchann] =
              channel_name: rchann
              channel_codec_quality: 10
              channel_description: "Root channel for match #{mid}."
              channel_flag_permanent: 1
              channel_password: "#{match.Info.Owner}"
            currentChannels["Radiant #{mid}"] =
              channel_name: "Radiant #{mid}"
              channel_codec_quality: 10
              channel_description: "Radiant channel for match #{mid}."
              channel_flag_permanent: 1
              channel_password: "#{match.Info.Owner}"
              pid: rchann
            currentChannels["Dire #{mid}"] =
              channel_name: "Dire #{mid}"
              channel_codec_quality: 10
              channel_description: "Dire channel for match #{mid}."
              channel_flag_permanent: 1
              channel_password: "#{match.Info.Owner}"
              pid: rchann
            currentChannels["Spectator #{mid} #1"] =
              channel_name: "Spectator #{mid} #1"
              channel_codec_quality: 10
              channel_description: "Spectator #1 channel for match #{mid}."
              channel_flag_permanent: 1
              #channel_password: "#{match.Info.Owner}"
              pid: rchann
        for id, chan of defaultChannels
          currentChannels[id] = chan
        for id, chan of currentServerChannels
          continue unless defaultChannels[id]?
          currentChannels[id] = chan if currentChannels[id]?
        _.keys(currentChannels).forEach (id)->
          chan = currentChannels[id]
          return if _.isString(chan.pid)
          if !currentServerChannels[id]?
            cl.send 'channelcreate', chan, (err, res)->
              if err?
                log "unable to create channel #{id}, #{util.inspect err}"
              else
                cl.send 'channelfind', {pattern: id}, (err, pchan)->
                  if err?
                    log "can't find channel I just created, #{util.inspect err}"
                    return
                  chan.cid = pchan.cid
                  log "created channel #{chan.channel_name}"
                  subchans = _.filter _.values(currentChannels), (schan)-> schan.pid is id
                  subchans.forEach (schan)->
                    schan.cpid = schan.pid = chan.cid
                    log schan
                    cl.send 'channelcreate', schan, (err, resp)->
                      if err?
                        log "unable to create channel #{schan.channel_name}, #{util.inspect err}"
                      else
                        log "created channel #{schan.channel_name}"

        for id, chan of currentServerChannels
          if !currentChannels[id]? and !(chan.channel_flag_permanent == 1 && chan.channel_description.indexOf("adminperm") > -1)
            log util.inspect chan
            if lastClients?
              for client in lastClients
                moveClientToHome(client, currentServerChannels) if client.cid is chan.cid
            cl.send 'channeldelete', {force: 1, cid: chan.cid}, (err)->
              if err?
                log "unable to delete #{id}, #{util.inspect err}"
              else
                log "deleted channel #{id}"

        cl.send 'clientlist', ['uid', 'away', 'voice', 'times', 'groups', 'info'], (err, clients)->
          if err?
            log "unable to fetch clients, #{util.inspect err}"
            return nextUpdate()

          return nextUpdate() if !clients?
          clients = [clients] if _.isObject(clients) and !_.isArray(clients)

          invGroups = _.invert serverGroups
          lastClients = clients

          nUsrCache = {}
          for id, usr of userCache
            if _.findWhere(clients, {client_unique_identifier: id})? && usr.nextUpdate<(new Date().getTime())
              nUsrCache[id] = usr
          userCache = nUsrCache

          checkClient = (client, user)->
            targetGroups = []

            if user?
              if user._id not in onlineUsers
                User.update {_id: user._id}, {$set: {tsonline: true}}, (err)->
                  if err?
                    console.log "Unable to mark #{user._id} as tsonline, #{err}"
                  else
                    console.log "Marked #{user._id} as online"

              onlineUsersNow.push user._id if user._id not in onlineUsersNow

            if !user? or !user.vouch?
              targetGroups.push parseInt invGroups["Guest"]
            else if "admin" in user.authItems
              targetGroups.push parseInt invGroups["Server Admin"]
            else
              targetGroups.push parseInt invGroups["Normal"]

            groups = []
            if _.isNumber client.client_servergroups
              groups.push client.client_servergroups
            else if _.isString client.client_servergroups
              groups = client.client_servergroups.split(',').map(parseInt)

            for id in targetGroups
              unless id in groups
                log "adding server group #{serverGroups[id]} to #{client.client_nickname}"
                cl.send 'servergroupaddclient', {sgid: id, cldbid: client.client_database_id}, (err)->
                  if err?
                    log "unable to assign group, #{util.inspect err}"

            for id in groups
              unless id in targetGroups
                log "removing server group #{serverGroups[id]} from #{client.client_nickname}"
                cl.send 'servergroupdelclient', {sgid: id, cldbid: client.client_database_id}, (err, resp)->
                  if err?
                    log "unable to remove group, #{util.inspect err}"

            uchan = currentChannels["Unknown"]
            if user?
              uplyr = null
              umatch = _.find matches, (match)->
                return false if match.Info.MatchType > 1
                uplyr = _.findWhere(match.Details.Players, {SID: user.steam.steamid})
                uplyr? and uplyr.Team < 2
              mid = null
              teamn = null
              cname = null
              if umatch?
                mid = umatch.Details.MatchId
                teamn = if uplyr.Team is 0 then "Radiant" else "Dire"
                cname = teamn+" "+mid
              if umatch? && currentChannels[cname]? && currentChannels[cname].cid? && currentChannels[cname].cid isnt 0
                tchan = currentChannels[cname]
                if tchan.cid isnt client.cid
                  log "moving client #{client.client_nickname} into #{cname}"
                  cl.send 'clientmove', {cid: tchan.cid, clid: client.clid}, (err)->
                    if err?
                      log "unable to move client to channel... #{util.inspect err}"
              else
                tchan = currentChannels["Lobby"]
                bchan = currentChannels["Bounce"]
                if ((bchan? and bchan.cid? and client.cid is bchan.cid) or (uchan.cid? && client.cid is uchan.cid)) && (tchan.cid? && tchan.cid != 0)
                  log "moving client #{client.client_nickname} out of unknown/bounce channel"
                  if user.vouch.leagues? && user.vouch.leagues.length > 0
                    moveClientToHome(client, currentServerChannels)
                  else
                    cl.send 'clientmove', {cid: tchan.cid, clid: client.clid}, (err)->
                      if err?
                        log "unable to move client to lobby... #{util.inspect err}"
            else
              tchan = currentChannels["Unknown"]
              if tchan.cid? && tchan.cid != 0 && client.cid isnt tchan.cid
                log "moving client #{client.client_nickname} to the unknown channel"
                cl.send 'clientmove', {cid: tchan.cid, clid: client.clid}, (err)->
                  if err?
                    log "unable to move client to unknown channel... #{util.inspect err}"
              unless client.clid in messagedUids
                messagedUids.push client.clid
                cl.send 'sendtextmessage', {targetmode: 1, target: client.clid, msg: "Welcome to the FPL teamspeak. Please paste your token here. Read the description of this channel for instructions if needed."}, (err)->
                  if err?
                    log "can't send text message to #{client.client_nickname}, #{util.inspect err}"
                  setTimeout ->
                    messagedUids = _.without messagedUids, client.clid
                  , 30000

          clids = []
          invGroups = _.invert serverGroups
          nonPlayer = invGroups["NonPlayer"]
          clients.forEach (client)->
            return unless client.client_type is 0
            return if nonPlayer? and "#{client.client_servergroups}" is nonPlayer
            clids.push client.clid
            uid = client.client_unique_identifier
            user = userCache[uid]

            if !user? and uid not in checkedUids
              checkedUids.push uid
              User.findOne {tsuniqueids: uid}, (err, usr)->
                if err?
                  log "unable to lookup #{uid}, #{util.inspect err}"
                  return
                if usr?
                  user = userCache[uid] = usr.toObject()
                checkClient client, user
            else
              checkClient client, user

          checkedUids = _.union clids

          for onlineu in onlineUsers
            unless onlineu in onlineUsersNow
              User.update {_id: onlineu}, {$set: {tsonline: false}}, (err)->
                if err?
                  console.log "Unable to set user #{onlineu} to offline, #{err}"
                else
                  console.log "Marked user #{onlineu} as offline"
          onlineUsers = onlineUsersNow
          onlineUsersNow = []

          nextUpdate()

initClient()
