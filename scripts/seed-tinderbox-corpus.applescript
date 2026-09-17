-- Create a NEW Tinderbox document and save it to argv 1 (POSIX path).
-- Never tells "front document". Closes only the document this script created.
-- Invoked by scripts/seed-tinderbox-corpus.sh after path guards.
on run argv
	if (count of argv) < 1 then error "usage: seed-tinderbox-corpus.applescript /abs/path.tbx"
	set destPosix to item 1 of argv
	if destPosix does not start with "/" then error "destination must be an absolute POSIX path"
	if destPosix contains "/Desktop/" then error "refusing Desktop paths"
	if destPosix contains "grokbot-tinderboris" then error "refusing playground tree"

	tell application "Tinderbox 11"
		set newDoc to make new document with properties {name:"Grok-Bot-Feature-Corpus-seed"}
		save newDoc in destPosix
		tell newDoc
			my ensureStringAttr(it, "BorisId")
			my ensureStringAttr(it, "BorisParent")
			my ensureStringAttr(it, "BorisStatus")
			my ensureStringAttr(it, "ExportClass")
			my ensureStringAttr(it, "FixtureRole")
			my ensureStringAttr(it, "MapsToBoris")

			try
				make new linkType with properties {name:"agree"}
			end try
			try
				make new linkType with properties {name:"disagree"}
			end try
			try
				make new linkType with properties {name:"example"}
			end try
			try
				make new linkType with properties {name:"clarify"}
			end try

			if (count of notes) > 0 then
				set rootNote to first note
				set name of rootNote to "Grok-Bot-Feature-Corpus-seed"
			else
				set rootNote to make new note with properties {name:"Grok-Bot-Feature-Corpus-seed"}
			end if
			tell rootNote
				set value of attribute "BorisId" to "grok-bot-seed"
				set value of attribute "Text" to "Regenerable smoke document. Not the golden Feature Corpus."
			end tell

			set protoNote to make new note in rootNote with properties {name:"pConcept"}
			tell protoNote
				set value of attribute "IsPrototype" to true
				set value of attribute "Text" to "Prototype: conceptual note."
			end tell

			set hub to make new note in rootNote with properties {name:"Typed links hub"}
			tell hub
				set value of attribute "BorisId" to "grok-bot-seed/links"
				set value of attribute "BorisParent" to "grok-bot-seed"
				set value of attribute "Text" to "Named basic links for relation-map tests."
				set value of attribute "Prototype" to "pConcept"
			end tell

			set targetNote to make new note in rootNote with properties {name:"Alias target"}
			tell targetNote
				set value of attribute "BorisId" to "grok-bot-seed/alias-target"
				set value of attribute "BorisParent" to "grok-bot-seed"
				set value of attribute "Text" to "Canonical destination for named links."
			end tell

			set emphasis to make new note in rootNote with properties {name:"Emphasis sample"}
			tell emphasis
				set value of attribute "BorisId" to "grok-bot-seed/emphasis"
				set value of attribute "BorisParent" to "grok-bot-seed"
				set value of attribute "Text" to "Hello bold and italic"
			end tell

			set nested to make new note in hub with properties {name:"Nested child"}
			tell nested
				set value of attribute "BorisId" to "grok-bot-seed/links/child"
				set value of attribute "BorisParent" to "grok-bot-seed/links"
				set value of attribute "Text" to "Outline depth sample."
			end tell

			evaluate hub with "linkTo(\"Alias target\",\"agree\")"
			evaluate hub with "linkTo(\"Alias target\",\"disagree\")"
			evaluate hub with "linkTo(\"Emphasis sample\",\"example\")"
			evaluate nested with "linkTo(\"Alias target\",\"clarify\")"
			evaluate hub with "linkTo(\"Nested child\")"
		end tell
		save newDoc
		close newDoc saving yes
	end tell
	return destPosix
end run

on ensureStringAttr(theDoc, attrName)
	tell theDoc
		try
			attribute named attrName
		on error
			set newAttr to make new attribute
			set type of newAttr to "string"
			set name of newAttr to attrName
		end try
	end tell
end ensureStringAttr
