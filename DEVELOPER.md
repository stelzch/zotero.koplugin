# Overview

Changed the sqlite data base structure such that it is aware of the relationship between different entities. Hopefully this will make it easier to propagate changes (e.g. deletion of a parent item removing attachments from view, etc).
The layout of the DB is loosely based on the one of the Zotero desktop client without implementing the advanced features.
To maintain compatibility the item info is still saved as a JSON blob in a separate table (itemData), which might become redundant at some point...
 
# Development plan:

- [x] Get basic library sync functionality to work

	Mostly implemented (except deletion of collections) on 27/10/24

- [] Display Zotero annotations on Koreader

	Rough implementation working 27/10/24

- [] Fix known issues listed below

- [] Saved searches?

- [] Support extra meta data, e.g. tags or all autors

### Random coding details:

- [] Make use of 'itemAttachments' table
	- [] use it to track synced version
	- [] use it to identify children
	- [] Store all attachment details in there?
	
- [x] Make an 'itemAnnotation' table
	- [] use it to track synced version
	- [x] use it to identify children

- [] remove redundant code

- [] proper implementation of libraries
	- [] set user and ID
	- [] use it to store version


# Known issues:

- [x] 'All items' or search results don't open when clicked (inherited from devStelzch)

	Fixed 29/10/24
	
- [x] Search returns deleted items (inherited from devStelzch)

	Fixed 29/10/24

- [] Offline collection functionality is currently disabled
	- Plan: use 'sync' column in collections table
	[x] use synced column in collections table
	[] change routines that select offline collections to update sync column
	
- [] Opening non-pdf files currently leads to a crash if there are annotations as the page size routines do not work

- [] Annotation sync to Zotero is currently disabled

- [] Re-sync library function currently not working:
	- 'collections' table is empty after re-sync for some reason.
	- Workaround: delete zotero.db
	- Plan: maybe implement this programatically: delete (or better move db to backup file) to initiate re-sync?
	
- [] If an item has several attachments, the one opened by default (1st?) might not be the one you want
	- Workaround: long click should present a list of all attachments
	- Plan: define an order/default attachment? What does desktop client do?
	
- [] Collection deletion not implemented yet; currently requires complete re-sync
