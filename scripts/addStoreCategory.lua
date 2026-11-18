-- Lampovo Project ^ω^ Average Enjoyer

local myloadStoreCategories = {}

local modDir = g_currentModDirectory
local modName = g_currentModName

function myloadStoreCategories.loadMapData(self, superFunc, xmlFile, missionInfo, baseDirectory)
    superFunc(self, xmlFile, missionInfo, baseDirectory)

    local xmlFile = XMLFile.load("ModFile", modDir .. "modDesc.xml")

    for _, key in xmlFile:iterator("modDesc.storeCategories.storeType") do
        g_storeManager:loadCategoryType(xmlFile, key, nil)
    end

    for _, key in xmlFile:iterator("modDesc.storeCategories.storeCategory") do
        g_storeManager:loadCategoryFromXML(xmlFile, key, modDir, modName)
    end

    local defaultIconFilename = "dataS/menu/construction/ui_construction_icons.png"
    local defaultRefSize = {256, 256}

    for _, key in xmlFile:iterator("modDesc.constructionCategories.constructionType") do
        local categoryName = xmlFile:getString(key .. "#name")
        local title = g_i18n:convertText(xmlFile:getString(key .. "#title"))
        local iconFilename = xmlFile:getString(key .. "#iconFilename") or defaultIconFilename
        local refSize = xmlFile:getVector(key .. "#refSize", defaultRefSize, 2)
        local iconUVs = GuiUtils.getUVs(xmlFile:getString(key .. "#iconUVs", "0 0 1 1"), refSize)
        local iconSliceId = xmlFile:getString(key .. "#iconSliceId")

        g_storeManager:addConstructionCategory(categoryName, title, iconFilename, iconUVs, "", iconSliceId)
    end

    for _, key in xmlFile:iterator("modDesc.constructionCategories.constructionCategory") do
        local categoryTypeName = xmlFile:getString(key .. "#type")
        local tabName = xmlFile:getString(key .. "#name")
        local tabTitle = g_i18n:convertText(xmlFile:getString(key .. "#title"))
        local tabIconFilename = xmlFile:getString(key .. "#iconFilename") or defaultIconFilename
        local tabRefSize = xmlFile:getVector(key .. "#refSize", defaultRefSize, 2)
        local tabIconUVs = GuiUtils.getUVs(xmlFile:getString(key .. "#iconUVs", "0 0 1 1"), tabRefSize)
        local tabIconSliceId = xmlFile:getString(key .. "#iconSliceId")

        g_storeManager:addConstructionTab(categoryTypeName, tabName, tabTitle, tabIconFilename, tabIconUVs, "", tabIconSliceId)
    end

    xmlFile:delete()

    return true
end

StoreManager.loadMapData = Utils.overwrittenFunction(StoreManager.loadMapData, myloadStoreCategories.loadMapData)
