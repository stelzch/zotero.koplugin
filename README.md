# Zotero for KOReader

This addon for [KOReader](https://github.com/koreader/koreader) allows you to view your Zotero collections.

> [!NOTE]
> **Beta version**! Please report bugs, pull requests are welcome.

<div align="center"><img width="600" alt="Screenshot of this plugin displaying a list of papers alongside a search button" src="https://raw.githubusercontent.com/stelzch/screencasts/main/zotero-koplugin-screenshot.png"></div>

## Features
* Synchronization via Zotero Web API
* Open attached PDF/EPUB/HTML files
* Download Zotero annotations of pdf files
* Upload new KOReader annotations on pdf files to Zotero
* Automatically download items of selected collections at sync time
* Supports WebDAV storage backend
* Search entries by the title of the publication or name of the first author.

### Limitations

* Currently, this plugin _only supports uploading new annotations_ made with KOReader to Zotero. Changes and deletions made in KOReader will not be synchronized. But changes made in Zotero will be synchronised.
* Annotations only work for pdf files, not epub or other
* Search function currently quite limited, no real access to full author lists, DOIs, tags, etc.


## Installation Guide
1. Ensure you are running the latest version of KOReader
2. Copy the files in this repository to `<KOReader>/plugins/zotero.koplugin`
3. Obtain an API token for your account by generating a new key in your [Zotero Settings](https://www.zotero.org/settings/keys). Note the userID and the private key.
5. If applicable, obtain username and password for your WebDAV storage (see below).
6. Set your credentials for Zotero either directly in KOReader or edit the configuration file as described [below](#manual-configuration).


## Configuration

### WebDAV support
If you do not want to pay Zotero for more storage, you can also store the attachments in a WebDAV folder like [Nextcloud](https://nextcloud.com).  You can read more about how to set up WebDAV in the [Zotero manual](https://www.zotero.org/support/sync).

The WebDAV URL should point to a directory named zotero. If you use Nextcloud, it will look similar to this: [http://your-instance.tld/remote.php/dav/files/your-username/zotero](). It is probably a good idea to use an app password instead of your user password, so that you can easily revoke it in the security settings should you ever lose your device.

### Manual configuration

If you do not want to type in the account credentials on your E-Reader, you can also edit the settings file directly.
Edit the `zotero/meta.lua` file inside the koreader directory and supply needed values:
```lua
return {
    ["api_key"] = "",           -- Zotero API secret key
    ["user_id"] = "",           -- API user ID, should be an integer number
    ["webdav_enabled"] = false, -- set to true if you use WebDAV to store attachments
    ["webdav_url"] = "",        -- URL to WebDAV zotero directory
    ["webdav_user"] = "",
    ["webdav_password"] = "",
}
```
