# Overview

Changed the sqlite data base structure such that it is aware of the relationship between different entities. Hopefully this will make it easier to propagate changes (e.g. deletion of a parent item removing attachments from view, etc).
The layout of the DB is loosely based on the one of the Zotero desktop client without implementing the advanced features.
To maintain compatibility the item info is still saved as a JSON blob in a separate table (itemData), which might become redundant at some point... **Note: Need to review if this is still the case after multiple updates and if database can be simplified**

# Development plan:

- [ ] Keep track and allow to open recent documents from plugin

- [ ] Fix known issues listed below

- [ ] Saved searches?

- [ ] Support extra meta data, e.g. tags or all authors

- [x] Get basic library sync functionality to work

	Mostly implemented (except deletion of collections) on 27/10/24

- [x] Display Zotero annotations on Koreader

# Known issues:
- [ ] When a file is opened from History / FileBrowser even after sync, the sdr is not updated
- [ ] Changing the color of an annotation on the device is not syncing with the server. It does work the other way around
- [ ] If an item has several attachments, the one opened by default (1st?) might not be the one you want
	- Workaround: long click should present a list of all attachments
	- Plan: define an order/default attachment? What does desktop client do?
- [ ] On device (KoBo Elipsa) the Sync complete message will not show up sometimes, however the sync will be succesfull
- [ ] Basic implementation working: but for nested collections there are still issues
- [x] 'All items' or search results don't open when clicked (inherited from devStelzch)

### Random coding details:

- [ ] Make use of 'itemAttachments' table
	- [x] use it to track synced version
	- [ ] use it to identify children
	- [ ] Store all attachment details in there?
		- [ ] file name
		- [ ] file type
		- [ ] link type
		- [ ] 'title'

- [x] Make an 'itemAnnotation' table
	- [ ] use it to track synced version
	- [x] use it to identify parent

- [x] remove redundant code
	- Removed majority of redundant code, just need left some placeholder methods if they need to be re-implemented in the future

- [ ] proper implementation of libraries
	- [ ] set user and ID
	- [ ] use it to store version

- [ ] Detect downloaded files by checking file system? E.g. after database reset everything gets downloaded agin even if there is a local copy...

- [ ] Option to do a database re-check (to avoid complete re-sync)



	Fixed 29/10/24

- [x] Search returns deleted items (inherited from devStelzch)

	Fixed 29/10/24

- [x] Offline collection functionality is currently disabled
	- Plan: use 'sync' column in collections table
	[x] use synced column in collections table
	[x] change routines that select offline collections to update 'synced' column

	Re-enabled 04/11/24

- [x] Opening non-pdf files currently leads to a crash if there are annotations as the page size routines do not work

	Fixed

- [x] Annotation sync to Zotero is currently disabled

	Re-enabled. 08/11/24
	Working, but Christoph's and my annotation system are still separate. Needs tidying

- [x] Re-sync library function currently not working:
	- 'collections' table is empty after re-sync for some reason. [I think this was bug in my code]
	- Workaround: delete zotero.db
	- Plan: maybe implement this programatically: delete (or better move db to backup file) to initiate re-sync?


- [x] Collection deletion not implemented yet; currently requires complete re-sync


- [x] Deleting annotations on Zotero does not seem to propagate to KOReader plugin if it already had been synced before deletion
