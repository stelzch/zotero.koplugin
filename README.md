# Zotero for KOReader

This addon for [KOReader](https://github.com/koreader/koreader) allows you to view your Zotero collections.

> [!NOTE]
> **Beta version**! Please report bugs, pull requests are welcome.

<div align="center"><img width="600" alt="Screenshot of this plugin displaying a list of papers alongside a search button" src="https://raw.githubusercontent.com/stelzch/screencasts/main/zotero-koplugin-screenshot.png"></div>

## Features
* Synchronize via Web API
* Display collections, navigate to sub-collections
* Download & open attached PDF files
* Supports WebDAV storage backend
* Search entries by the title of the publication, name of the first author or DOI.




## Installation Guide
1. Copy the files in this repository to `<KOReader>/plugins/zotero.koplugin`
2. Obtain an API token for your account by generating a new key in your [Zotero Settings](https://www.zotero.org/settings/keys). Note the userID and the private key.
3. Set your credentials for Zotero either directly in KOReader or edit the configuration file as described [below](#manual-configuration).


### Differences to previous  versions
In previous versions, you had to copy your entire Zotero directory to your device.
The new version however works with the Zotero Web API and downloads attachments ad-hoc.
If you are not interested in syncing your collection and would rather access your entire collection offline, you can take a look at version [0.1](https://github.com/stelzch/zotero.koplugin/releases/tag/0.1).

## Configuration

### WebDAV support
If you do not want to pay Zotero for more storage, you can also store the attachments in a WebDAV folder like [Nextcloud](https://nextcloud.com).
You can read more about how to set up WebDAV in the [Zotero manual](https://www.zotero.org/support/sync).

The WebDAV URL should point to a directory named zotero. If you use Nextcloud, it will look similar to this: [http://your-instance.tld/remote.php/dav/files/your-username/zotero](). It is probably a good idea to use an app password instead of your user password, so that you can easily revoke it in the security settings should you ever lose your device.

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
