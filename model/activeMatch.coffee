'use strict'
mongoose = require('mongoose')
Schema = mongoose.Schema
crypto = require('crypto')

ActiveMatchSchema = mongoose.Schema(
  _id: Buffer
  Details:
    _id: Buffer
    Players: [ {
      SID: String
      Name: String
      Avatar: String
      Team: Number
      Ready: Boolean
      IsCaptain: Boolean
      IsLeaver: Boolean
      LeaverReason: Number
      Rating: Number
      Hero:
        _id: Number
        name: String
        fullName: String
    } ]
    GameMode: Number
    Bot:
      _id: String
      Username: String
      Password: String
      Invalid: Boolean
      InUse: Boolean
    Password: String
    Status: Number
    State: Number
    MatchId: Number
    SpectatorCount: Number
    FirstBloodHappened: Boolean
    GameStartTime: Date
    IsRecovered: Boolean
    ServerSteamID: String
  Info:
    _id: Buffer
    MatchType: Number
    Public: Boolean
    Status: Number
    Owner: String
    GameMode: Number
    Opponent: String
    CaptainStatus: Number)

module.exports = mongoose.model('activeMatches', ActiveMatchSchema, 'activeMatches')
