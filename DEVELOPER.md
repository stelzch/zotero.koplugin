# Overview

Changed the sqlite data base structure such that the DB is aware of the relationship between different entities. Hopefully this will make it easier to propagate changes (e.g. deletion of a parent item removing attachments from view, etc).
The layout of the DB is loosely based on the one of the Zotero desktop client without implementing the advanced features.
To maintain compatibility the item info is still saved as a JSON blob in a separate table (itemData), which might become redundant at some point...
 
# Development plan:

- [] Get basic library sync functionality to work

- [] Display Zotero annotations on Koreader

- [] Fix known issues listed below

- [] Save searches?

- [] Support extra meta data, e.g. tags or all autors


# Known issues:

- [] 'All items' or search results don't open (inherited from devStelzch)

- [] Search returns deleted items (inherited from devStelzch)

- [] Offline collection functionality is currently disabled
	- Plan: use 'sync' collumn in collections table

- [] Annotation sync to Zotero is currently disabled

- [] Re-sync library function currently not working:
	- 'collections' table is empty after re-sync for some reason.
	- Workaround: delete zotero.db
	- Plan: maybe implement this programatically: delete (or better move db to backup file) to initiate re-sync?
	
- [] If an item has several attachments, to one opened by default (1st?) might not be the one you want
	- Workaround: long click should present a list of all attachments
	- Plan: define an order/default attachment? What does desktop client do?
