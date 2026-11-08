"""Clearinghouse: the AuctionIQ companion app.

Pulls Blizzard's Auction House data on a schedule, keeps a local price history, and writes it into
the Clearinghouse addon folder for AuctionIQ to read in game. It only writes into
AddOns/Clearinghouse: never WoW's SavedVariables and never TradeSkillMaster's files.
"""

__version__ = "0.1.0"
