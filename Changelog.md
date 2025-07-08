# Change Log

## [JA 1.0 RC4] - 2025-07-07
### Added
- Added use of network manager when connecting to prevent connection errors and toggling automatic wifi connection
- Added automatic setting of not writing annotation to pdf in files used by Zotero.koplugin. This behavior can be changed in the settings dialog

### Changed
- Removed SyncItemAnnotations method which wasn't used and also removed unused imports
- Updated debug logs so it can be easily filtered for Zotero

### Fixed
- Fixed deletions, these now work properly both in client and server side
- Bug where highlight color in KOReader was different from the color in Zotero

## [JA 1.0 RC3] - 2025-01-05

### Added
- Add custom metadata to downloaded Zotero items, so that it shows up correctly in the KO reader file browser: title, authors, abstract (as book description) and tags (as keywords).
- In Zotero browser a long-press now shows a page listing
	- the available bibliographic data for the item (type, journal, year, pages, etc)
	- Abstract and tags
	- List of attachments
- Option the scan the local storage to make sure the database knows about all the downloaded files

### Changed
- Allow 'multi-line' entries in the Zotero browser. Looks a bit ugly with different entries having a different font sizes, but can often see the complete title...
- Library info now also displays the library name

### Fixed
- Stop non-pdf attachments being re-downloaded
- Ignore annotations without a 'drawer' when syncing
- Use the color defined in Zotero when adding them as KO reader annotations (so far always used default, i.e. yellow)


---
## [JA 1.0 RC2] - 2024-12-07

### Added
- Display 'path' as a subtitle in the Zotero browser
- For searches, display the query as subtitle
- Keep track of the last time library was synced with Zotero server
- Can specify default colour of annotations uploaded to Zotero by setting 'annotation_default_color' in `zotero\meta.lua` configuration file
- Notification if upload of annotation has failed
- Added document describing database structure (DevelopmentNotes.md)

### Changed
- Modified sqlite database structure, so no longer compatible with [JA 1.0 RC]. If there is an existing sqlite library it would have to be completely re-synced!
- But new structure should make it possible to update the sqlite library from within the plugin if there are future changes...

### Fixed
- HEX color codes getting rejected by Zotero API

---
## [JA 1.0 RC] - 2024-11-??

### Added
- Use https calls to connect to Zotero server (as well as the webdav server if used)
- Display items which are not part of any collection in the library root
- Sync and attach existing Zotero annotations to downloaded files. Currently only works for pdf files and 'highlight' or 'underline' style annotations.
- Option to re-analyse local database items to try and sort out issues (relatively quick and no connection to server needed)
- Added menu item to display the plugin's version number and some basic info about the database


### Changed
- Keep Zotero library in an updated sqlite database, which is aware of some relationships between items, collection, etc.


### Fixed
- Search not displaying any results
- Remove zip file used for webdav downloads
