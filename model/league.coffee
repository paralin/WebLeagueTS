mongoose = require('mongoose')
Schema = mongoose.Schema
crypto = require('crypto')

LeagueSchema = mongoose.Schema({
  _id: String,
  Name: String,
  IsActive: Boolean,
  Archived: Boolean,
  CurrentSeason: Number,
  Seasons: [{
    Name: String,
    Prizepool: Number,
    PrizepoolCurrency: String,
    Start: Date,
    End: Date,
    Ticket: Number
  }]
})

module.exports = mongoose.model('leagues', LeagueSchema, "leagues")
