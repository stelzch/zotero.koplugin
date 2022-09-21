describe("Zotero API Client", function()
    local orig_path = package.path
    local API_KEY = os.getenv("ZOTERO_API_KEY")
    local USER_ID = os.getenv("ZOTERO_USER_ID")

    assert.truthy(API_KEY)
    assert.truthy(USER_ID)

    package.path = "plugins/zotero.koplugin/?.lua;" .. package.path
    require("commonrequire")
    local ZoteroAPI = require("zoteroapi")
    package.path = orig_path

    ZoteroAPI.init("/tmp/zoteroplugin")
    ZoteroAPI.setAPIKey(API_KEY)
    ZoteroAPI.setUserID(USER_ID)

    local headers = {
        ["Zotero-API-Key"] = API_KEY,
        ["Zotero-API-Version"] = "3"
    }

    print("'" .. headers["Zotero-API-Key"] .. "'")

    --it("can tell the size of collections", function()
    --    local r, e = ZoteroAPI.fetchCollectionSize(
    --        ("https://api.zotero.org/users/%s/items"):format(USER_ID), headers
    --    )
    --    print(e,r)
    --    assert.is_nil(e)
    --    assert.is_true(r >= 0)
    --    print("Collection size: ", r)
    --end)

    --it("can fetch a paginated collection", function()
    --    local items_url = ("https://api.zotero.org/users/%s/items?since=%s"):format(USER_ID, 0)

    --    local r, e
    --    local collection_size = ZoteroAPI.fetchCollectionSize(items_url, headers)
    --    local r, e = ZoteroAPI.fetchCollectionPaginated(items_url, headers)

    --    assert.is_nil(e)
    --    assert.is_equal(collection_size, #r)

    --end)

    it("should be able to sync items", function()
        local e = ZoteroAPI.syncItems()
        assert.is_nil(e)
    end)

    it("can download files", function()
        local e  = ZoteroAPI.downloadFile("9E9TBDVH")
        assert.is_nil(e)

    end)


    --it("can read the correct version number", function()
    --    local nr = ZoteroAPI.getLibraryVersion()
    --    assert.is_equal(nr, "1147")
    --end)
end)

