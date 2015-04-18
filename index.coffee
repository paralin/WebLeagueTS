mongoose = require "mongoose"
ActiveMatch = require "./model/activeMatch"
User        = require "./model/user"
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

tsUser = process.env.TEAMSPEAK_USER
if !tsUser?
  console.log "TEAMSPEAK_USER env variable required!"
  return

tsPassword = process.env.TEAMSPEAK_PASSWORD
if !tsPassword?
  console.log "TEAMSPEAK_PASSWORD env variable required!"
  return

mongoose.connect(process.env.MONGODB_URL)

defaultChannels =
  "Lobby":
    channel_name: "Lobby"
    channel_codec_quality: 10
    channel_flag_default: 1
    channel_flag_permanent: 1
    channel_description: "General chat."
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
  "[spacer0]":
    channel_name: "[spacer0]"
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
checkedUids = []
messagedUids = []

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
  cl = new TeamSpeakClient(tsIp)
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

      uid = client.client_unique_identifier
      User.findOne {tsonetimeid: msg.msg}, (err, usr)->
        if err?
          log "unable to lookup tsonetimeid #{msg.msg}, #{util.inspect err}"
          return
        if usr?
          cl.send 'sendtextmessage', {targetmode: 1, target: msg.invokerid, msg: "Welcome, #{usr.profile.name}!"}
          cl.send 'clientedit', {clid: msg.invokerid, client_description: usr.profile.name}, (err)->
            if err?
              log "Unable to edit client #{client.cid}, #{util.inspect err}"
          user = userCache[uid] = usr.toObject()
          User.update {_id: usr._id}, {$set: {tsuniqueids: [uid], tsonetimeid: null}}, (err)->
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

updateTeamspeak = (myid)->
  if myid != cid or !connected
    log "terminating old update loop #{myid}"
    return

  currentChannels = {}
  currentServerChannels = {}
  pend = cl.getPending()
  updcalled = false

  nextUpdate = ->
    return if npdcalled
    npdcalled = true
    setTimeout ->
      updateTeamspeak(myid)
    , 1000

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

    # First check acive matches
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
        else
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
          currentChannels["Broadcaster #{mid} #1"] =
            channel_name: "Broadcaster #{mid} #1"
            channel_codec_quality: 10
            channel_description: "Broadcaster channel for match #{mid}."
            channel_flag_permanent: 1
            channel_password: "#{match.Info.Owner}"
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
        if !currentChannels[id]?
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

        checkClient = (client, user)->
          targetGroups = []
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
              if uchan.cid? && client.cid is uchan.cid && tchan.cid? && tchan.cid != 0
                log "moving client #{client.client_nickname} out of unknown channel"
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

        nextUpdate()

initClient()
