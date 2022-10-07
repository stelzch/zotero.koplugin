describe("Zotero API Client", function()
    local orig_path = package.path
    local API_KEY = os.getenv("ZOTERO_API_KEY")
    local USER_ID = os.getenv("ZOTERO_USER_ID")
    assert.truthy(API_KEY)
    assert.truthy(USER_ID)

    package.path = "plugins/zotero.koplugin/?.lua;" .. package.path
    require("commonrequire")
    local JSON = require("json")
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

    --it("should be able to sync items", function()
    --    local e = ZoteroAPI.syncAllItems()
    --    assert.is_nil(e)
    --end)

    --it("can download files", function()
    --    local r, e  = ZoteroAPI.downloadAndGetPath("9E9TBDVH")
    --    assert.is_nil(e)

    --end)

    --it("can round floating point numbers", function()
    --    local f = ZoteroAPI.cutDecimalPlaces

    --    assert.is_equal(f(math.pi, 4), 3.1415)
    --    assert.is_equal(f(10, 0), 10)
    --    assert.is_equal(f(10.12341234, 0), 10)
    --    assert.is_equal(f(10, 4), 10)
    --end)

    --it("can convert bounding boxes", function()
    --    local r = ZoteroAPI.bboxFromZotero({
    --        [1] = 123.63,
    --        [2] = 593.859,
    --        [3] = 176.164,
    --        [4] = 604.895
    --    })

    --    print(JSON.encode(r))
    --    assert.is_true(
    --    ZoteroAPI.bboxEqual(r, {
    --        ["x"] = 123.63,
    --        ["y"] = 593.859,
    --        ["w"] = 52.534,
    --        ["h"] = 11.0351
    --    }, 10^-3))

    --end)

    --it("can show a list of entries", function()
    --    local rootEntries = ZoteroAPI.displayCollection()
    --    assert.is_true(#rootEntries > 0)
    --    assert.is_not_nil(rootEntries[1].name)
    --    assert.is_not_nil(rootEntries[1].key)

    --    local entries = ZoteroAPI.displayCollection("J6HRKTMY")
    --    assert.is_true(#entries > 0)
    --    assert.is_not_nil(entries[1].name)
    --    assert.is_not_nil(entries[1].key)
    --end)

    --it("can search for entries", function()
    --    local results = ZoteroAPI.displaySearchResults("sybil")
    --    assert.is_true(#results == 1)
    --    assert.is_not_nil(results[1].name)
    --    assert.is_not_nil(results[1].key)
    --    assert.is_nil(results[1].collection)
    --end)

    --it("can correctly format timestamps #time", function()
    --    local r1 = ZoteroAPI.addTimezone("2022-09-22 18:09:12")

    --    assert.is_equal("2022-09-22T16:09:12Z", r1)
    --end)


    --it("can read the correct version number", function()
    --    local nr = ZoteroAPI.getLibraryVersion()
    --    assert.is_equal(nr, "1147")
    --end)

    it("can sync annotations", function()
        ZoteroAPI.syncAnnotations("H3XITXUG")
    end)

end)

