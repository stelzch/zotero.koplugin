# Overview

Changed the sqlite data base structure such that the DB is aware of the relationship between different entities. Hopefully this will make it easier to propagate changes (e.g. deletion of a parent item removing attachments from view, etc).
The layout of the DB is loosely based on the one of the Zotero desktop client without implementing the advanced features.
To maintain compatibility the item info is still saved as a JSON blob in a separate table (itemData), which might become redundant at some point...
 
# Development plan:

- Get basic library sync functionality to work

- Display Zotero annotations on Koreader

- Sync back local annotations


# Known issues:

- 'All items' or search results don't open (inherited from devStelzch)

- Search returns deleted items (inherited from devStelzch)

- Offline collection functionality is currently disabled

- Annotation sync to Zotero is currently disabled

- Re-sync library function currently not working:
	- 'collections' table is empty after re-sync for some reason.
	- Workaround: delete zotero.db
