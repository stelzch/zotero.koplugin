# Zotero for KOReader

This addon for [KOReader](https://github.com/koreader/koreader) allows you to view your Zotero collections.

## Features
* Display collections, navigate to sub-collections
* Download & open attached PDF files
* Supports WebDAV storage backend
* Search entries by the title of the publication, name of the first author or DOI.


## Installation Guide
1. Copy the files in this repository to `<KOReader>/plugins/zotero.koplugin`
2. Obtain an API token for your account by generating a new key in your [Zotero Settings](https://www.zotero.org/settings/keys). Note the userID and the private key.
3. Set your credentials for Zotero either directly in KOReader or edit the configuration file as described [below](#manual-configuration).

## Configuration

### WebDAV support
If you do not want to pay Zotero for more storage, you can also store the attachments in a WebDAV folder like [Nextcloud](https://nextcloud.com).
You can read more about how to set up WebDAV in the [Zotero manual](https://www.zotero.org/support/sync).

### Manual configuration

If you do not want to type in the account credentials on your E-Reader, you can also edit the settings file directly.
Edit the `zotero/meta.lua` file inside the koreader directory and supply needed values:
```lua
-- we can read Lua syntax here!
return {
    ["api_key"] = "", -- API secret key
    ["user_id"] = "", -- API user ID, should be an integer number
    ["webdav_enabled"] = false,
    ["webdav_url"] = "", -- URL to WebDAV zotero directory
    ["webdav_user"] = "",
    ["webdav_password"] = "",
}
```
