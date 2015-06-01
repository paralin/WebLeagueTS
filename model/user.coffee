mongoose = require('mongoose')
Schema = mongoose.Schema
crypto = require('crypto')

UserSchema = mongoose.Schema({
  _id: String,
  authItems: [String],
  profile: {
    name: String,
    leagues: Object
  },
  vouch: {
    _id: String,
    name: String,
    avatar: String,
    leagues: [String]
  },
  steam: {
    steamid: String,
    communityvisibilitystate: Number,
    profilestate: Number,
    personaname: String,
    lastlogoff: Number,
    commentpermission: Number,
    profileurl: String,
    avatar: String,
    avatarmedium: String,
    avatarfull: String,
    personastate: Number,
    realname: String,
    primaryclanid: String,
    timecreated: Number,
    personastateflags: Number,
    gameextrainfo: String,
    gameid: String,
    loccountrycode: String,
    locstatecode: String,
    loccityid: Number
  },
  settings: {
    language: String,
    sounds: {},
    soundMuted: Boolean
  },
  channels: [String],
  tsuniqueids: [String],
  tsonetimeid: String,
  tsonline: Boolean
})

module.exports = mongoose.model('users', UserSchema)
