describe("Zotero API Client", function()
    --local orig_path = package.path
    --local API_KEY = os.getenv("ZOTERO_API_KEY")
    --local USER_ID = os.getenv("ZOTERO_USER_ID")
    --assert.truthy(API_KEY)
    --assert.truthy(USER_ID)

    --package.path = "plugins/zotero.koplugin/?.lua;" .. package.path
    --require("commonrequire")
    --local JSON = require("json")
    --local ZoteroAPI = require("zoteroapi")
    --package.path = orig_path

    --ZoteroAPI.init("/tmp/zoteroplugin")
    --ZoteroAPI.setAPIKey(API_KEY)
    --ZoteroAPI.setUserID(USER_ID)

    --local headers = {
    --    ["Zotero-API-Key"] = API_KEY,
    --    ["Zotero-API-Version"] = "3"
    --}

    it("can execute tests", function()
        assert.is_true(true)
    end)


end)

